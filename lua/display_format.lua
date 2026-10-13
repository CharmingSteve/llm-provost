-- Client-side display normalization for inline <reasoning> tags.
--
-- Bedrock's OpenAI-compatible endpoint returns gpt-oss reasoning inline in
-- the message content as <reasoning>...</reasoning>. Clients such as
-- LibreChat only render reasoning from a reasoning_content field or <think>
-- tags, so with REASONING_DISPLAY enabled this module rewrites the
-- client-bound response body:
--
--   off    (default) no-op; the hook never calls into the transform
--   openai moves the reasoning into reasoning_content (message field for
--          JSON responses, delta field for SSE streams)
--   think  renames the tags to <think>...</think> inside content
--
-- The mode is read once when the module loads; changing it requires a
-- container reload. The audit log is unaffected: audit_body.capture reads
-- the upstream chunk before this module rewrites ngx.arg[1].
--
-- Tags are recognized only where gpt-oss emits them: at the start of the
-- content, and again directly after a closing tag (whitespace allowed), so
-- consecutive tag pairs merge into one reasoning span. A literal <reasoning>
-- quoted later in an answer passes through untouched. Apart from the tags
-- themselves, no content bytes are dropped or duplicated.
local cjson = require("cjson.safe").new()

-- Re-encoding must not turn [] into {}, escape "/" or round numbers.
if cjson.decode_array_with_array_mt then
    cjson.decode_array_with_array_mt(true)
end
if cjson.encode_escape_forward_slash then
    cjson.encode_escape_forward_slash(false)
end
pcall(cjson.encode_number_precision, 16)

local _M = {}

local OPEN_TAG = "<reasoning>"
local CLOSE_TAG = "</reasoning>"
local THINK_OPEN_TAG = "<think>"
local THINK_CLOSE_TAG = "</think>"

-- Whitespace held after a closing tag while waiting to learn whether
-- another tag pair follows.
local MAX_HELD_WHITESPACE = 4096
-- Bodies past these limits pass through unmodified rather than buffering.
local MAX_JSON_BODY_BYTES = 8 * 1024 * 1024
local MAX_SSE_EVENT_BYTES = 1024 * 1024

local MODES = { off = true, openai = true, think = true }

local function configured_mode()
    local value = os.getenv("REASONING_DISPLAY")
    if value == nil or value == "" then
        return "off"
    end
    value = value:lower()
    if MODES[value] then
        return value
    end
    if ngx and ngx.log then
        ngx.log(ngx.WARN, "unknown REASONING_DISPLAY value '", value, "'; reasoning display is off")
    end
    return "off"
end

_M.mode = configured_mode()
_M.enabled = _M.mode ~= "off"

-- Length of the longest proper prefix of tag that text ends with.
local function held_tag_prefix(text, tag)
    for length = math.min(#text, #tag - 1), 1, -1 do
        if text:sub(-length) == tag:sub(1, length) then
            return length
        end
    end
    return 0
end

local Splitter = {}
Splitter.__index = Splitter

-- Phases: start (tag may open here) -> reasoning -> after_close (another tag
-- pair may follow) -> back to reasoning, or content once anything else
-- arrives. pending holds bytes that could still be part of a tag.
function _M.new_splitter(mode)
    return setmetatable({ mode = mode, phase = "start", pending = "" }, Splitter)
end

function Splitter:emit_reasoning(out, text)
    if text == "" then
        return
    end
    if self.mode == "think" then
        out.content[#out.content + 1] = text
    else
        out.reasoning[#out.reasoning + 1] = text
    end
end

function Splitter:emit_close(out)
    if self.mode == "think" then
        out.content[#out.content + 1] = THINK_CLOSE_TAG
    end
end

-- Returns the content and reasoning text this delta contributes.
function Splitter:feed(text)
    local out = { content = {}, reasoning = {} }
    local buffered = self.pending .. (text or "")
    self.pending = ""

    while true do
        local phase = self.phase
        if phase == "content" then
            out.content[#out.content + 1] = buffered
            break
        elseif phase == "reasoning" then
            local close_at = buffered:find(CLOSE_TAG, 1, true)
            if not close_at then
                local held = held_tag_prefix(buffered, CLOSE_TAG)
                self:emit_reasoning(out, buffered:sub(1, #buffered - held))
                self.pending = buffered:sub(#buffered - held + 1)
                break
            end
            self:emit_reasoning(out, buffered:sub(1, close_at - 1))
            buffered = buffered:sub(close_at + #CLOSE_TAG)
            self.phase = "after_close"
        else
            -- start or after_close: is a tag opening here?
            local lead = phase == "after_close" and buffered:match("^%s*") or ""
            local rest = buffered:sub(#lead + 1)
            if rest:sub(1, #OPEN_TAG) == OPEN_TAG then
                if phase == "start" and self.mode == "think" then
                    out.content[#out.content + 1] = THINK_OPEN_TAG
                end
                -- Whitespace between two tag pairs separates reasoning blocks.
                self:emit_reasoning(out, lead)
                buffered = rest:sub(#OPEN_TAG + 1)
                self.phase = "reasoning"
            elseif OPEN_TAG:sub(1, #rest) == rest and #lead <= MAX_HELD_WHITESPACE then
                self.pending = buffered
                break
            else
                if phase == "after_close" then
                    self:emit_close(out)
                end
                out.content[#out.content + 1] = buffered
                self.phase = "content"
                break
            end
        end
    end
    return table.concat(out.content), table.concat(out.reasoning)
end

-- Releases held bytes at end of stream as literal text.
function Splitter:flush()
    local out = { content = {}, reasoning = {} }
    local phase, pending = self.phase, self.pending
    self.phase, self.pending = "content", ""
    if phase == "reasoning" then
        self:emit_reasoning(out, pending)
    else
        if phase == "after_close" then
            self:emit_close(out)
        end
        out.content[#out.content + 1] = pending
    end
    return table.concat(out.content), table.concat(out.reasoning)
end

-- Splits a complete message; equivalent to streaming it in one delta.
function _M.split(mode, text)
    local splitter = _M.new_splitter(mode)
    local content, reasoning = splitter:feed(text)
    local flushed_content, flushed_reasoning = splitter:flush()
    return content .. flushed_content, reasoning .. flushed_reasoning
end

-- Writes split output into a message or delta table; returns true when it
-- differs from the original.
local function apply_split(target, original, content, reasoning)
    local unchanged = reasoning == ""
        and (content == original or (original == nil and content == ""))
    if unchanged then
        return false
    end
    target.content = content
    if reasoning ~= "" then
        local existing = type(target.reasoning_content) == "string" and target.reasoning_content or ""
        target.reasoning_content = existing .. reasoning
    end
    return true
end

local function transform_json_body(mode, body)
    local decoded = cjson.decode(body)
    if type(decoded) ~= "table" or type(decoded.choices) ~= "table" then
        return body
    end

    local changed = false
    for _, choice in ipairs(decoded.choices) do
        local message = type(choice) == "table" and choice.message or nil
        if type(message) == "table" and type(message.content) == "string" then
            local content, reasoning = _M.split(mode, message.content)
            changed = apply_split(message, message.content, content, reasoning) or changed
        end
    end
    if not changed then
        return body
    end
    return cjson.encode(decoded) or body
end

local JsonTransformer = {}
JsonTransformer.__index = JsonTransformer

function JsonTransformer:feed(chunk, eof)
    if self.passthrough then
        return chunk
    end
    self.buffer[#self.buffer + 1] = chunk
    self.bytes = self.bytes + #chunk
    if self.bytes > MAX_JSON_BODY_BYTES then
        self.passthrough = true
        return table.concat(self.buffer)
    end
    if not eof then
        return ""
    end
    return transform_json_body(self.mode, table.concat(self.buffer))
end

local SseTransformer = {}
SseTransformer.__index = SseTransformer

local function event_boundary(value)
    local lf_start, lf_end = value:find("\n\n", 1, true)
    local crlf_start, crlf_end = value:find("\r\n\r\n", 1, true)
    if crlf_start and (not lf_start or crlf_start < lf_start) then
        return crlf_start, crlf_end
    end
    return lf_start, lf_end
end

function SseTransformer:splitter(index)
    local splitter = self.splitters[index]
    if not splitter then
        splitter = _M.new_splitter(self.mode)
        self.splitters[index] = splitter
        self.order[#self.order + 1] = index
    end
    return splitter
end

-- A synthetic chunk carrying text still held when the stream ends without
-- a finish_reason for its choice. Empty when nothing is held.
function SseTransformer:flush_event(separator)
    local choices = {}
    for _, index in ipairs(self.order) do
        local content, reasoning = self.splitters[index]:flush()
        if content ~= "" or reasoning ~= "" then
            choices[#choices + 1] = {
                index = index,
                delta = { content = content, reasoning_content = reasoning ~= "" and reasoning or nil },
                finish_reason = cjson.null,
            }
        end
    end
    if #choices == 0 then
        return ""
    end
    local meta = self.meta or {}
    local payload = {
        id = meta.id,
        object = meta.object or "chat.completion.chunk",
        created = meta.created,
        model = meta.model,
        choices = choices,
    }
    return "data: " .. assert(cjson.encode(payload)) .. separator .. separator
end

function SseTransformer:transform_payload(payload)
    if type(payload) ~= "table" or type(payload.choices) ~= "table" then
        return false
    end
    self.meta = { id = payload.id, object = payload.object, created = payload.created, model = payload.model }

    local changed = false
    for position, choice in ipairs(payload.choices) do
        if type(choice) == "table" then
            local index = type(choice.index) == "number" and choice.index or position - 1
            local splitter = self:splitter(index)
            local delta = type(choice.delta) == "table" and choice.delta or nil
            local original = delta and type(delta.content) == "string" and delta.content or nil
            local content, reasoning = "", ""
            if original then
                content, reasoning = splitter:feed(original)
            end
            if choice.finish_reason ~= nil and choice.finish_reason ~= cjson.null then
                local flushed_content, flushed_reasoning = splitter:flush()
                content, reasoning = content .. flushed_content, reasoning .. flushed_reasoning
            end
            local target = delta or {}
            if apply_split(target, original, content, reasoning) then
                choice.delta = target
                changed = true
            end
        end
    end
    return changed
end

-- Rewrites one SSE event (without its terminating blank line). Only data:
-- payloads change; other fields and comments keep their original lines.
function SseTransformer:transform_event(event)
    local separator = event:find("\r\n", 1, true) and "\r\n" or "\n"
    local lines, data_lines, first_data = {}, {}, nil
    for line in (event .. separator):gmatch("(.-)" .. separator) do
        lines[#lines + 1] = line
        local data = line:match("^data: ?(.*)$")
        if data then
            data_lines[#data_lines + 1] = data
            first_data = first_data or #lines
        end
    end
    if not first_data then
        return event
    end

    local data = table.concat(data_lines, "\n")
    if data == "[DONE]" then
        return self:flush_event(separator) .. event
    end
    local payload = cjson.decode(data)
    if not self:transform_payload(payload) then
        return event
    end
    local encoded = cjson.encode(payload)
    if not encoded then
        return event
    end

    local rebuilt = {}
    for index, line in ipairs(lines) do
        if index == first_data then
            rebuilt[#rebuilt + 1] = "data: " .. encoded
        elseif not line:match("^data:") then
            rebuilt[#rebuilt + 1] = line
        end
    end
    return table.concat(rebuilt, separator)
end

function SseTransformer:feed(chunk, eof)
    if self.passthrough then
        return chunk
    end
    local out = {}
    local buffer = self.buffer .. chunk
    while true do
        local boundary_start, boundary_end = event_boundary(buffer)
        if not boundary_start then
            break
        end
        out[#out + 1] = self:transform_event(buffer:sub(1, boundary_start - 1))
        out[#out + 1] = buffer:sub(boundary_start, boundary_end)
        buffer = buffer:sub(boundary_end + 1)
    end

    if #buffer > MAX_SSE_EVENT_BYTES then
        out[#out + 1] = self:flush_event("\n")
        out[#out + 1] = buffer
        buffer = ""
        self.passthrough = true
    elseif eof then
        if buffer ~= "" then
            out[#out + 1] = self:transform_event(buffer)
        end
        local held = self:flush_event("\n")
        if held ~= "" and buffer ~= "" then
            out[#out + 1] = "\n\n"
        end
        out[#out + 1] = held
        buffer = ""
    end
    self.buffer = buffer
    return table.concat(out)
end

-- kind is "json" or "sse".
function _M.new_transformer(mode, kind)
    if kind == "sse" then
        return setmetatable({ mode = mode, buffer = "", splitters = {}, order = {} }, SseTransformer)
    end
    return setmetatable({ mode = mode, buffer = {}, bytes = 0 }, JsonTransformer)
end

function _M.response_kind(content_type, content_encoding)
    if content_encoding ~= nil and content_encoding ~= "" and content_encoding ~= "identity" then
        return nil
    end
    content_type = tostring(content_type or ""):lower()
    if content_type:find("text/event-stream", 1, true) then
        return "sse"
    end
    if content_type:find("application/json", 1, true) then
        return "json"
    end
    return nil
end

-- Per-request transformer in ngx.ctx; false when the response is not
-- rewritable (unknown content type or compressed body).
local function request_transformer()
    local transformer = ngx.ctx.display_format
    if transformer == nil then
        local kind = _M.response_kind(ngx.header.content_type, ngx.header.content_encoding)
        transformer = kind and _M.new_transformer(_M.mode, kind) or false
        ngx.ctx.display_format = transformer
    end
    return transformer
end

-- Header phase: a rewritten body no longer matches the upstream length.
function _M.header_filter()
    if request_transformer() then
        ngx.header.content_length = nil
    end
end

-- Body phase: returns the client-bound replacement for the chunk.
function _M.body_filter(chunk, eof)
    local transformer = request_transformer()
    if not transformer then
        return chunk
    end
    return transformer:feed(chunk or "", eof)
end

return _M
