-- Translates OpenAI chat completions to and from the Amazon Bedrock Converse
-- API, so every Bedrock chat model (Claude, Llama, Nova, Mistral, ...) is
-- reachable through the one OpenAI-shaped /llm/v1 endpoint.
--
--   request   translate_request(body)  -> { body, path, state }
--   response  header_filter() / body_filter(chunk, eof)
--             JSON responses, error responses and the binary
--             application/vnd.amazon.eventstream of ConverseStream are
--             rewritten into OpenAI JSON / SSE for the client.
--
-- State travels in ngx.ctx.bedrock_converse between the policy phase and the
-- response filters.
local cjson = require("cjson.safe")

local json = cjson.new and cjson.new() or cjson
if json.decode_array_with_array_mt then
    -- Keep empty arrays (e.g. JSON-schema "required": []) arrays on re-encode.
    json.decode_array_with_array_mt(true)
end
local NULL = json.null
local EMPTY_ARRAY = json.empty_array or setmetatable({}, json.empty_array_mt)

local _M = {}

local MAX_BUFFERED_BYTES = 8 * 1024 * 1024
local MAX_FRAME_BYTES = 16 * 1024 * 1024

local FINISH_REASONS = {
    end_turn = "stop",
    stop_sequence = "stop",
    max_tokens = "length",
    model_context_window_exceeded = "length",
    tool_use = "tool_calls",
    content_filtered = "content_filter",
    guardrail_intervened = "content_filter",
}

local IMAGE_FORMATS = { png = "png", jpeg = "jpeg", jpg = "jpeg", gif = "gif", webp = "webp" }

local function clean(value)
    if value == NULL then
        return nil
    end
    return value
end

local function url_escape(value)
    return (value:gsub("[^%w%-_%.~]", function(char)
        return string.format("%%%02X", char:byte())
    end))
end

local function truncate(value, limit)
    value = tostring(value or "")
    if #value > limit then
        return value:sub(1, limit)
    end
    return value
end

-- ---------------------------------------------------------------------------
-- Request: OpenAI chat completion -> Converse
-- ---------------------------------------------------------------------------

local function text_parts(content)
    content = clean(content)
    if type(content) == "string" then
        return content
    end
    if type(content) ~= "table" then
        return ""
    end
    local parts = {}
    for _, part in ipairs(content) do
        if type(part) == "table" and part.type == "text" and type(part.text) == "string" then
            parts[#parts + 1] = part.text
        end
    end
    return table.concat(parts, "\n")
end

local function image_block(part)
    local image = clean(part.image_url)
    local url = type(image) == "table" and image.url or image
    if type(url) ~= "string" then
        return nil, "image_url must be a string or an object with a url"
    end
    local mime, data = url:match("^data:image/([%w%.%+%-]+);base64,(.+)$")
    local format = mime and IMAGE_FORMATS[mime:lower()]
    if not format then
        return nil, "image_url must be a base64 data URI (png, jpeg, gif or webp)"
    end
    return { image = { format = format, source = { bytes = data } } }
end

local function user_blocks(content)
    content = clean(content)
    if type(content) == "string" then
        return content ~= "" and { { text = content } } or {}
    end
    if type(content) ~= "table" then
        return {}
    end
    local blocks = {}
    for _, part in ipairs(content) do
        if type(part) ~= "table" then
            return nil, "invalid content part"
        elseif part.type == "text" then
            if type(part.text) == "string" and part.text ~= "" then
                blocks[#blocks + 1] = { text = part.text }
            end
        elseif part.type == "image_url" then
            local block, err = image_block(part)
            if not block then
                return nil, err
            end
            blocks[#blocks + 1] = block
        else
            return nil, "unsupported content part type: " .. tostring(part.type)
        end
    end
    return blocks
end

local function tool_use_block(call)
    local fn = type(call) == "table" and type(call["function"]) == "table" and call["function"]
    if not fn or type(fn.name) ~= "string" or type(call.id) ~= "string" then
        return nil, "invalid tool call in assistant message"
    end
    local input = {}
    if type(fn.arguments) == "string" and fn.arguments ~= "" then
        local decoded = json.decode(fn.arguments)
        if type(decoded) == "table" then
            input = decoded
        end
    end
    return { toolUse = { toolUseId = call.id, name = fn.name, input = input } }
end

local function convert_messages(messages)
    local system, out, has_tools = {}, {}, false

    local function push(role, blocks)
        if #blocks == 0 then
            return
        end
        local last = out[#out]
        if last and last.role == role then
            for _, block in ipairs(blocks) do
                last.content[#last.content + 1] = block
            end
        else
            out[#out + 1] = { role = role, content = blocks }
        end
    end

    for _, message in ipairs(messages) do
        if type(message) ~= "table" or type(message.role) ~= "string" then
            return nil, nil, "each message needs a role"
        end
        local role = message.role
        if role == "system" or role == "developer" then
            local text = text_parts(message.content)
            if text ~= "" then
                system[#system + 1] = { text = text }
            end
        elseif role == "user" then
            local blocks, err = user_blocks(message.content)
            if not blocks then
                return nil, nil, err
            end
            push("user", blocks)
        elseif role == "assistant" then
            local blocks, err = user_blocks(message.content)
            if not blocks then
                return nil, nil, err
            end
            local calls = clean(message.tool_calls)
            if type(calls) == "table" then
                for _, call in ipairs(calls) do
                    local block, call_err = tool_use_block(call)
                    if not block then
                        return nil, nil, call_err
                    end
                    has_tools = true
                    blocks[#blocks + 1] = block
                end
            end
            push("assistant", blocks)
        elseif role == "tool" then
            if type(message.tool_call_id) ~= "string" then
                return nil, nil, "tool message needs a tool_call_id"
            end
            local text = text_parts(message.content)
            has_tools = true
            push("user", { {
                toolResult = {
                    toolUseId = message.tool_call_id,
                    content = { { text = text ~= "" and text or "(no output)" } },
                },
            } })
        else
            return nil, nil, "unsupported message role: " .. role
        end
    end
    return system, out, nil, has_tools
end

local function convert_tools(tools, tool_choice, has_tool_history)
    tools = clean(tools)
    if type(tools) ~= "table" or #tools == 0 then
        return nil
    end
    tool_choice = clean(tool_choice)
    if tool_choice == "none" and not has_tool_history then
        return nil
    end
    local specs = {}
    for _, tool in ipairs(tools) do
        local fn = type(tool) == "table" and tool.type == "function" and tool["function"]
        if type(fn) ~= "table" or type(fn.name) ~= "string" then
            return nil, "unsupported tool definition"
        end
        local schema = clean(fn.parameters)
        if type(schema) ~= "table" then
            schema = { type = "object", properties = {} }
        end
        local spec = { name = fn.name, inputSchema = { json = schema } }
        if type(fn.description) == "string" and fn.description ~= "" then
            spec.description = fn.description
        end
        specs[#specs + 1] = { toolSpec = spec }
    end
    local config = { tools = specs }
    if tool_choice == "required" then
        config.toolChoice = { any = {} }
    elseif type(tool_choice) == "table" and type(tool_choice["function"]) == "table"
        and type(tool_choice["function"].name) == "string" then
        config.toolChoice = { tool = { name = tool_choice["function"].name } }
    elseif tool_choice == "auto" then
        config.toolChoice = { auto = {} }
    end
    return config
end

local function inference_config(request)
    local config = {}
    local max_tokens = tonumber(clean(request.max_completion_tokens) or clean(request.max_tokens))
    if max_tokens and max_tokens >= 1 then
        config.maxTokens = math.floor(max_tokens)
    end
    local temperature = tonumber(clean(request.temperature))
    if temperature then
        config.temperature = temperature
    end
    local top_p = tonumber(clean(request.top_p))
    if top_p then
        config.topP = top_p
    end
    local stop = clean(request.stop)
    if type(stop) == "string" then
        config.stopSequences = { stop }
    elseif type(stop) == "table" and #stop > 0 then
        config.stopSequences = stop
    end
    return next(config) and config or nil
end

-- Returns { body = <converse json>, path = <signed request path>, state = {...} },
-- or nil and a client-facing message.
function _M.translate_request(raw)
    local request = json.decode(raw or "")
    if type(request) ~= "table" then
        return nil, "request body must be a JSON object"
    end
    local model = request.model
    if type(model) ~= "string" or model == "" then
        return nil, "model is required"
    end
    local messages = clean(request.messages)
    if type(messages) ~= "table" then
        return nil, "messages must be an array"
    end

    local system, converted, err, has_tool_history = convert_messages(messages)
    if not system then
        return nil, err
    end
    if #converted == 0 then
        return nil, "messages must include at least one user or assistant message with content"
    end

    local converse = { messages = converted }
    if #system > 0 then
        converse.system = system
    end
    converse.inferenceConfig = inference_config(request)
    local tool_config, tool_err = convert_tools(request.tools, request.tool_choice, has_tool_history)
    if tool_err then
        return nil, tool_err
    end
    converse.toolConfig = tool_config

    local body = json.encode(converse)
    if not body then
        return nil, "request could not be translated"
    end
    local stream = clean(request.stream) == true
    local options = clean(request.stream_options)
    return {
        body = body,
        path = "/model/" .. url_escape(model) .. (stream and "/converse-stream" or "/converse"),
        state = {
            model = model,
            stream = stream,
            include_usage = type(options) == "table" and options.include_usage == true,
        },
    }
end

-- ---------------------------------------------------------------------------
-- Response: Converse -> OpenAI chat completion
-- ---------------------------------------------------------------------------

local function completion_id()
    local request_id = ngx and ngx.var and ngx.var.request_id
    return "chatcmpl-" .. (request_id or tostring(os.time()))
end

local function convert_usage(usage)
    usage = clean(usage)
    if type(usage) ~= "table" then
        return nil
    end
    local prompt = tonumber(usage.inputTokens) or 0
    local completion = tonumber(usage.outputTokens) or 0
    local converted = {
        prompt_tokens = prompt,
        completion_tokens = completion,
        total_tokens = tonumber(usage.totalTokens) or (prompt + completion),
    }
    local cached = tonumber(usage.cacheReadInputTokens)
    if cached then
        converted.prompt_tokens_details = { cached_tokens = cached }
    end
    return converted
end

-- Returns the OpenAI JSON for a Converse response body, or nil and a reason.
function _M.convert_response(raw, state)
    local response = json.decode(raw or "")
    local message = type(response) == "table" and type(response.output) == "table"
        and response.output.message
    if type(message) ~= "table" or type(message.content) ~= "table" then
        return nil, "unexpected Bedrock response"
    end
    local text, reasoning, calls = {}, {}, {}
    for _, block in ipairs(message.content) do
        if type(block.text) == "string" then
            text[#text + 1] = block.text
        elseif type(block.toolUse) == "table" then
            local input = json.encode(block.toolUse.input or {}) or "{}"
            calls[#calls + 1] = {
                id = block.toolUse.toolUseId,
                type = "function",
                ["function"] = { name = block.toolUse.name, arguments = input },
            }
        elseif type(block.reasoningContent) == "table"
            and type(block.reasoningContent.reasoningText) == "table"
            and type(block.reasoningContent.reasoningText.text) == "string" then
            reasoning[#reasoning + 1] = block.reasoningContent.reasoningText.text
        end
    end
    local out = { role = "assistant", content = #text > 0 and table.concat(text) or NULL }
    if #reasoning > 0 then
        out.reasoning_content = table.concat(reasoning)
    end
    if #calls > 0 then
        out.tool_calls = calls
    end
    return json.encode({
        id = completion_id(),
        object = "chat.completion",
        created = os.time(),
        model = state.model,
        choices = { {
            index = 0,
            message = out,
            finish_reason = FINISH_REASONS[response.stopReason] or "stop",
        } },
        usage = convert_usage(response.usage),
    })
end

local function error_type(status)
    if status == 400 or status == 422 then
        return "invalid_request_error"
    elseif status == 401 then
        return "authentication_error"
    elseif status == 403 then
        return "permission_error"
    elseif status == 404 then
        return "not_found_error"
    elseif status == 429 then
        return "rate_limit_error"
    end
    return "server_error"
end

-- Shapes a Bedrock error body as an OpenAI error; the HTTP status is kept.
function _M.convert_error(raw, status, aws_type)
    local decoded = json.decode(raw or "")
    local message
    if type(decoded) == "table" then
        message = clean(decoded.message) or clean(decoded.Message)
    end
    if type(message) ~= "string" or message == "" then
        message = truncate(raw ~= "" and raw or "Bedrock request failed", 500)
    end
    local code = type(aws_type) == "string" and aws_type:match("^([^:]+)") or nil
    return json.encode({
        error = {
            message = truncate(message, 2000),
            type = error_type(status),
            param = NULL,
            code = code or NULL,
        },
    })
end

-- ---------------------------------------------------------------------------
-- Streaming: application/vnd.amazon.eventstream -> OpenAI SSE
-- ---------------------------------------------------------------------------

local function u32(data, index)
    local a, b, c, d = data:byte(index, index + 3)
    return ((a * 256 + b) * 256 + c) * 256 + d
end

local FIXED_HEADER_SIZES = { [0] = 0, [1] = 0, [2] = 1, [3] = 2, [4] = 4, [5] = 8, [8] = 8, [9] = 16 }

local function parse_headers(data)
    local headers, pos = {}, 1
    while pos <= #data do
        local name_len = data:byte(pos)
        local name = data:sub(pos + 1, pos + name_len)
        local kind = data:byte(pos + name_len + 1)
        pos = pos + name_len + 2
        if kind == 7 or kind == 6 then
            local hi, lo = data:byte(pos, pos + 1)
            local len = hi * 256 + lo
            if kind == 7 then
                headers[name] = data:sub(pos + 2, pos + 1 + len)
            end
            pos = pos + 2 + len
        elseif FIXED_HEADER_SIZES[kind] then
            pos = pos + FIXED_HEADER_SIZES[kind]
        else
            return nil
        end
    end
    return headers
end

-- Splits complete frames off the front of the buffer. Frame CRCs are not
-- checked: the transport is TLS-protected.
-- Returns events ({ type, kind, payload }) and the remaining buffer, or nil
-- when the framing is corrupt.
function _M.decode_frames(buffer)
    local events = {}
    while #buffer >= 12 do
        local total = u32(buffer, 1)
        local headers_len = u32(buffer, 5)
        if total < 16 or total > MAX_FRAME_BYTES or headers_len > total - 16 then
            return nil
        end
        if #buffer < total then
            break
        end
        local headers = parse_headers(buffer:sub(13, 12 + headers_len))
        if not headers then
            return nil
        end
        local payload = buffer:sub(13 + headers_len, total - 4)
        events[#events + 1] = {
            type = headers[":event-type"] or headers[":exception-type"],
            kind = headers[":message-type"] or "event",
            payload = payload,
        }
        buffer = buffer:sub(total + 1)
    end
    return events, buffer
end

local Stream = {}
Stream.__index = Stream

local function new_stream(state)
    return setmetatable({
        state = state,
        buffer = "",
        id = completion_id(),
        created = os.time(),
        tool_index = {},
        tool_count = 0,
        finished = false,
        failed = false,
    }, Stream)
end

local function sse(payload)
    return "data: " .. payload .. "\n\n"
end

function Stream:chunk(delta, finish, usage)
    local body = {
        id = self.id,
        object = "chat.completion.chunk",
        created = self.created,
        model = self.state.model,
        choices = delta and { { index = 0, delta = delta, finish_reason = finish or NULL } } or EMPTY_ARRAY,
        usage = usage,
    }
    return sse(json.encode(body))
end

function Stream:failure(message, status)
    self.failed = true
    return sse(json.encode({
        error = { message = truncate(message, 2000), type = error_type(status or 500), param = NULL, code = NULL },
    })) .. "data: [DONE]\n\n"
end

function Stream:event(event)
    if event.kind == "exception" then
        local decoded = json.decode(event.payload) or {}
        local status = event.type == "throttlingException" and 429 or 500
        return self:failure(clean(decoded.message) or tostring(event.type or "Bedrock stream error"), status)
    end
    local data = json.decode(event.payload)
    if type(data) ~= "table" then
        return ""
    end
    if event.type == "messageStart" then
        return self:chunk({ role = "assistant", content = "" })
    elseif event.type == "contentBlockStart" then
        local tool = type(data.start) == "table" and data.start.toolUse
        if type(tool) ~= "table" then
            return ""
        end
        local index = self.tool_count
        self.tool_count = index + 1
        self.tool_index[data.contentBlockIndex] = index
        return self:chunk({ tool_calls = { {
            index = index,
            id = tool.toolUseId,
            type = "function",
            ["function"] = { name = tool.name, arguments = "" },
        } } })
    elseif event.type == "contentBlockDelta" then
        local delta = data.delta
        if type(delta) ~= "table" then
            return ""
        end
        if type(delta.text) == "string" and delta.text ~= "" then
            return self:chunk({ content = delta.text })
        end
        if type(delta.toolUse) == "table" and type(delta.toolUse.input) == "string" then
            local index = self.tool_index[data.contentBlockIndex]
            if index then
                return self:chunk({ tool_calls = { {
                    index = index,
                    ["function"] = { arguments = delta.toolUse.input },
                } } })
            end
        elseif type(delta.reasoningContent) == "table" and type(delta.reasoningContent.text) == "string"
            and delta.reasoningContent.text ~= "" then
            return self:chunk({ reasoning_content = delta.reasoningContent.text })
        end
        return ""
    elseif event.type == "messageStop" then
        self.finished = true
        return self:chunk({}, FINISH_REASONS[data.stopReason] or "stop")
    elseif event.type == "metadata" then
        local usage = convert_usage(data.usage)
        if usage and self.state.include_usage then
            return self:chunk(nil, nil, usage)
        end
    end
    return ""
end

function Stream:feed(chunk, eof)
    if self.failed then
        return ""
    end
    self.buffer = self.buffer .. chunk
    local events, rest = _M.decode_frames(self.buffer)
    if not events then
        self.buffer = ""
        return self:failure("Invalid response stream from Bedrock", 502)
    end
    self.buffer = rest
    local out = {}
    for _, event in ipairs(events) do
        out[#out + 1] = self:event(event)
        if self.failed then
            return table.concat(out)
        end
    end
    -- An interrupted upstream stream gets no [DONE], so the client sees it.
    if eof and self.finished then
        out[#out + 1] = "data: [DONE]\n\n"
    end
    return table.concat(out)
end

-- ---------------------------------------------------------------------------
-- nginx filter phases
-- ---------------------------------------------------------------------------

function _M.header_filter()
    local state = ngx.ctx.bedrock_converse
    if not state then
        return
    end
    local status = ngx.status
    local content_type = tostring(ngx.header.content_type or ""):lower()
    local ok = status >= 200 and status < 300
    ngx.header.content_length = nil
    if ok and state.stream and content_type:find("vnd.amazon.eventstream", 1, true) then
        state.mode = "stream"
        state.stream_converter = new_stream(state)
        ngx.header.content_type = "text/event-stream"
    elseif ok and not state.stream and content_type:find("application/json", 1, true) then
        state.mode = "json"
        state.parts, state.bytes = {}, 0
    else
        state.mode = "error"
        state.status = status
        state.aws_type = ngx.header["x-amzn-ErrorType"]
        state.parts, state.bytes = {}, 0
        ngx.header.content_type = "application/json"
    end
end

function _M.body_filter(chunk, eof)
    local state = ngx.ctx.bedrock_converse
    if not state or not state.mode or state.passthrough then
        return chunk
    end
    chunk = chunk or ""
    if state.mode == "stream" then
        return state.stream_converter:feed(chunk, eof)
    end
    state.parts[#state.parts + 1] = chunk
    state.bytes = state.bytes + #chunk
    if state.bytes > MAX_BUFFERED_BYTES then
        state.passthrough = true
        local buffered = table.concat(state.parts)
        state.parts = nil
        return buffered
    end
    if not eof then
        return ""
    end
    local raw = table.concat(state.parts)
    if state.mode == "json" then
        local converted = _M.convert_response(raw, state)
        return converted or _M.convert_error(raw, 502, nil)
    end
    return _M.convert_error(raw, state.status, state.aws_type)
end

return _M
