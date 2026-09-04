local cjson = require("cjson.safe")

local _M = {}

local MAX_COMPACT_TEXT_BYTES = 8192
local MAX_FALLBACK_BYTES = 4096
local MAX_MODEL_IDS = 100
local MAX_PENDING_EVENT_BYTES = 65536
local MAX_REQUEST_LOG_BYTES = 4096
local MAX_REQUEST_TEXT_BYTES = 2048
local MAX_STREAM_SEGMENTS = 64

local SENSITIVE_KEYS = {
    api_key = true,
    apikey = true,
    authorization = true,
    password = true,
    secret = true,
    token = true,
}

local function valid_utf8_prefix_length(value, offset)
    local first = value:byte(offset)
    if not first or first < 0x80 then
        return first and 1 or 0
    end
    if first >= 0xC2 and first <= 0xDF then
        return 2
    end
    if first >= 0xE0 and first <= 0xEF then
        return 3
    end
    if first >= 0xF0 and first <= 0xF4 then
        return 4
    end
    return 0
end

local function is_valid_utf8_sequence(value, offset, length)
    if length == 1 then
        return true
    end
    if offset + length - 1 > #value then
        return false
    end

    local first = value:byte(offset)
    local second = value:byte(offset + 1)
    if not second or second < 0x80 or second > 0xBF then
        return false
    end
    if length == 2 then
        return true
    end

    local third = value:byte(offset + 2)
    if not third or third < 0x80 or third > 0xBF then
        return false
    end
    if first == 0xE0 and second < 0xA0 then
        return false
    end
    if first == 0xED and second > 0x9F then
        return false
    end
    if length == 3 then
        return true
    end

    local fourth = value:byte(offset + 3)
    if not fourth or fourth < 0x80 or fourth > 0xBF then
        return false
    end
    if first == 0xF0 and second < 0x90 then
        return false
    end
    if first == 0xF4 and second > 0x8F then
        return false
    end
    return true
end

local function sanitize(value)
    local parts = {}
    local offset = 1
    while offset <= #value do
        local length = valid_utf8_prefix_length(value, offset)
        if length > 0 and is_valid_utf8_sequence(value, offset, length) then
            parts[#parts + 1] = value:sub(offset, offset + length - 1)
            offset = offset + length
        else
            parts[#parts + 1] = string.format("\\x%02X", value:byte(offset))
            offset = offset + 1
        end
    end
    return table.concat(parts)
end

local function truncate_utf8(value, limit)
    if #value <= limit then
        return value, false
    end

    local offset = 1
    local last = 0
    while offset <= #value do
        local length = valid_utf8_prefix_length(value, offset)
        if length == 0 or offset + length - 1 > limit then
            break
        end
        last = offset + length - 1
        offset = last + 1
    end
    return value:sub(1, last), true
end

local function redact_sensitive(value)
    if type(value) ~= "table" then
        return value
    end

    local redacted = {}
    for key, child in pairs(value) do
        local normalized = type(key) == "string"
            and key:lower():gsub("[^a-z0-9]", "_")
            or ""
        if SENSITIVE_KEYS[normalized] or normalized:find("secret", 1, true) then
            redacted[key] = "[REDACTED]"
        else
            redacted[key] = redact_sensitive(child)
        end
    end
    return redacted
end

local function compact_message(message)
    if type(message) ~= "table" then
        return { content = tostring(message) }, false
    end

    local compacted = { role = message.role }
    local content = message.content
    if type(content) ~= "string" then
        content = cjson.encode(content) or tostring(content or "")
    end
    compacted.content, compacted.truncated = truncate_utf8(
        content, MAX_REQUEST_TEXT_BYTES
    )
    if not compacted.truncated then
        compacted.truncated = nil
    end
    return compacted, compacted.truncated == true
end

local function compact_messages(messages)
    if type(messages) ~= "table" then
        return messages, false
    end

    local summary = {
        count = #messages,
        omitted = math.max(#messages - 1, 0),
        roles = {},
    }
    local content_truncated = false
    for _, message in ipairs(messages) do
        local role = type(message) == "table" and tostring(message.role or "unknown") or "unknown"
        summary.roles[role] = (summary.roles[role] or 0) + 1
        if role == "system" and summary.system == nil then
            summary.system, content_truncated = compact_message(message)
        end
    end
    if #messages > 0 then
        local latest_truncated
        summary.latest, latest_truncated = compact_message(messages[#messages])
        content_truncated = content_truncated or latest_truncated
    end
    return summary, summary.omitted > 0 or content_truncated
end

local function compact_request_body(decoded, original_bytes)
    local result = {}
    local truncated = false
    for key, value in pairs(decoded) do
        if key == "messages" then
            result.messages, truncated = compact_messages(value)
        else
            result[key] = value
        end
    end
    if truncated then
        result.truncated = true
    end

    local encoded = cjson.encode(result)
    if encoded and #encoded <= MAX_REQUEST_LOG_BYTES then
        return encoded
    end

    local bounded = {
        model = result.model,
        stream = result.stream,
        user = result.user,
        messages = result.messages,
        original_bytes = original_bytes,
        truncated = true,
    }
    if result.method == "tools/call" and type(result.params) == "table" then
        local arguments = type(result.params.arguments) == "table"
            and result.params.arguments
            or {}
        local argument_keys = {}
        for key in pairs(arguments) do
            argument_keys[#argument_keys + 1] = tostring(key)
        end
        table.sort(argument_keys)
        bounded.method = result.method
        bounded.params = {
            name = result.params.name,
            arguments = {
                customer_id = arguments.customer_id,
                customer_name = arguments.customer_name,
                keys = argument_keys,
            },
        }
    end
    encoded = cjson.encode(bounded)
    if encoded and #encoded <= MAX_REQUEST_LOG_BYTES then
        return encoded
    end

    if type(bounded.messages) == "table" and type(bounded.messages.latest) == "table" then
        bounded.messages.latest.content = truncate_utf8(
            tostring(bounded.messages.latest.content or ""), 512
        )
        if type(bounded.messages.system) == "table" then
            bounded.messages.system.content = nil
            bounded.messages.system.truncated = true
        end
    end
    return cjson.encode(bounded)
end

local function append_text(parts, value)
    if type(value) == "string" then
        parts[#parts + 1] = value
        return true
    end
    if type(value) ~= "table" then
        return false
    end

    local found = false
    for _, part in ipairs(value) do
        if type(part) == "table" then
            local text = part.text or part.content
            if type(text) == "string" then
                parts[#parts + 1] = text
                found = true
            end
        end
    end
    return found
end

local function tool_call_key(call, fallback_index)
    local key = call.index or fallback_index or call.id
    if type(key) == "number" then
        return string.format("%.14g", key)
    end
    return tostring(key)
end

local function append_tool_call(state, call, fallback_index)
    if type(call) ~= "table" then
        return false
    end

    local key = tool_call_key(call, fallback_index)
    local current = state.tool_calls[key]
    if not current then
        current = { id = call.id, type = call.type, name = nil, arguments = "" }
        state.tool_calls[key] = current
        state.tool_order[#state.tool_order + 1] = key
    end

    current.id = call.id or current.id
    current.type = call.type or current.type
    local operation = call["function"] or call.function_call or call
    if type(operation) == "table" then
        current.name = operation.name or current.name
        local arguments = operation.arguments or operation.partial_json
        if type(arguments) == "string" then
            current.arguments = current.arguments .. arguments
        elseif type(arguments) == "table" and next(arguments) ~= nil then
            current.arguments = cjson.encode(arguments) or current.arguments
        end
    end
    return current.id ~= nil or current.name ~= nil or current.arguments ~= ""
end

local function consume_choice(state, choice)
    if type(choice) ~= "table" then
        return false
    end

    local payload = choice.delta or choice.message or choice
    local found = false
    if type(payload) == "table" then
        found = append_text(state.content, payload.content) or found
        found = append_text(state.reasoning, payload.reasoning_content) or found
        found = append_text(state.reasoning, payload.reasoning) or found
        found = append_text(state.reasoning, payload.analysis) or found
        if type(payload.tool_calls) == "table" then
            for index, call in ipairs(payload.tool_calls) do
                found = append_tool_call(state, call, index) or found
            end
        end
        if type(payload.function_call) == "table" then
            found = append_tool_call(state, payload.function_call, 1) or found
        end
    end
    if choice.finish_reason ~= nil then
        state.finish_reason = choice.finish_reason
        found = true
    end
    return found
end

local function consume_payload(state, payload)
    if type(payload) ~= "table" then
        return false
    end

    local found = false
    if type(payload.choices) == "table" then
        for _, choice in ipairs(payload.choices) do
            found = consume_choice(state, choice) or found
        end
    end

    found = append_text(state.content, payload.response) or found
    if type(payload.message) == "table" then
        found = append_text(state.content, payload.message.content) or found
        found = append_text(state.reasoning, payload.message.thinking) or found
        if type(payload.message.tool_calls) == "table" then
            for index, call in ipairs(payload.message.tool_calls) do
                found = append_tool_call(state, call, index) or found
            end
        end
    end

    local event_type = payload.type
    local delta = payload.delta
    if event_type == "content_block_delta" and type(delta) == "table" then
        found = append_text(state.content, delta.text) or found
        found = append_text(state.reasoning, delta.thinking) or found
        if type(delta.partial_json) == "string" then
            found = append_tool_call(state, { partial_json = delta.partial_json }, 1) or found
        end
    elseif type(event_type) == "string" and event_type:find("output_text.delta", 1, true) then
        found = append_text(state.content, delta) or found
    elseif type(event_type) == "string" and event_type:find("function_call_arguments.delta", 1, true) then
        found = append_tool_call(state, {
            id = payload.item_id,
            name = payload.name,
            arguments = delta,
        }, payload.output_index or 1) or found
    end

    if type(payload.content_block) == "table" and payload.content_block.type == "tool_use" then
        found = append_tool_call(state, {
            id = payload.content_block.id,
            name = payload.content_block.name,
            arguments = payload.content_block.input,
        }, payload.index or 1) or found
    end

    if type(payload.candidates) == "table" then
        for _, candidate in ipairs(payload.candidates) do
            local content = type(candidate) == "table" and candidate.content or nil
            if type(content) == "table" and type(content.parts) == "table" then
                for index, part in ipairs(content.parts) do
                    if type(part) == "table" then
                        found = append_text(state.content, part.text) or found
                        if type(part.functionCall) == "table" then
                            found = append_tool_call(state, part.functionCall, index) or found
                        end
                    end
                end
            end
            if type(candidate) == "table" and candidate.finishReason ~= nil then
                state.finish_reason = candidate.finishReason
                found = true
            end
        end
    end

    if type(payload.usage) == "table" then
        state.usage = payload.usage
        found = true
    elseif type(payload.usageMetadata) == "table" then
        state.usage = payload.usageMetadata
        found = true
    end
    return found
end

local function state_result(state, content, reasoning, truncated)
    local result = {}
    if content ~= "" then
        result.content = content
    end
    if reasoning ~= "" then
        result.reasoning = reasoning
    end
    if #state.tool_order > 0 then
        result.tool_calls = {}
        for _, key in ipairs(state.tool_order) do
            result.tool_calls[#result.tool_calls + 1] = state.tool_calls[key]
        end
    end
    if state.finish_reason ~= nil then
        result.finish_reason = state.finish_reason
    end
    if state.usage ~= nil then
        result.usage = state.usage
    end
    if truncated then
        result.truncated = true
    end
    return result
end

local function compact_state(state, truncated)
    local content, content_truncated = truncate_utf8(
        table.concat(state.content), MAX_COMPACT_TEXT_BYTES
    )
    local reasoning, reasoning_truncated = truncate_utf8(
        table.concat(state.reasoning), MAX_COMPACT_TEXT_BYTES
    )
    return cjson.encode(state_result(
        state,
        content,
        reasoning,
        truncated or content_truncated or reasoning_truncated
    ))
end

local function split_text(value)
    local parts = {}
    local remaining = value
    while remaining ~= "" do
        local part, has_more = truncate_utf8(remaining, MAX_COMPACT_TEXT_BYTES)
        parts[#parts + 1] = part
        remaining = remaining:sub(#part + 1)
        if not has_more then
            break
        end
    end
    if #parts == 0 then
        parts[1] = ""
    end
    return parts
end

local function compact_state_parts(state, truncated)
    local content_parts = split_text(table.concat(state.content))
    local reasoning_parts = split_text(table.concat(state.reasoning))
    local count = math.max(#content_parts, #reasoning_parts)
    local parts = {}
    for index = 1, count do
        local result = state_result(
            state,
            content_parts[index] or "",
            reasoning_parts[index] or "",
            truncated
        )
        if count > 1 then
            result.chunk = index
            result.chunks = count
        end
        parts[index] = cjson.encode(result)
    end
    return parts
end

local function compact_model_list(decoded)
    if type(decoded) ~= "table" or decoded.object ~= "list" or type(decoded.data) ~= "table" then
        return nil
    end

    local models = {}
    for index, model in ipairs(decoded.data) do
        if type(model) ~= "table" or type(model.id) ~= "string" then
            return nil
        end
        if index <= MAX_MODEL_IDS then
            models[#models + 1] = model.id
        end
    end

    local result = {
        object = "list",
        count = #decoded.data,
        models = models,
    }
    if #decoded.data > MAX_MODEL_IDS then
        result.truncated = true
    end
    return cjson.encode(result)
end

local function compact_fallback(raw, truncated)
    local bounded, bounded_truncated = truncate_utf8(raw, MAX_FALLBACK_BYTES)
    if truncated or bounded_truncated then
        return bounded .. "[truncated]"
    end
    return bounded
end

local function parse_sse(raw, truncated)
    local normalized = raw:gsub("\r\n", "\n")
    if truncated then
        local complete_end = normalized:match(".*()\n\n")
        if not complete_end then
            return nil
        end
        normalized = normalized:sub(1, complete_end)
    end
    local state = { content = {}, reasoning = {}, tool_calls = {}, tool_order = {} }
    local recognized = false
    local saw_data = false

    for event in (normalized .. "\n\n"):gmatch("(.-)\n\n") do
        local data_lines = {}
        for line in (event .. "\n"):gmatch("(.-)\n") do
            local data = line:match("^data:%s?(.*)$")
            if data then
                data_lines[#data_lines + 1] = data
            end
        end
        if #data_lines > 0 then
            saw_data = true
            local data = table.concat(data_lines, "\n")
            if data ~= "[DONE]" then
                local payload = cjson.decode(data)
                if type(payload) ~= "table" then
                    return nil
                end
                recognized = consume_payload(state, payload) or recognized
            end
        end
    end

    if not saw_data or not recognized then
        return nil
    end
    return state
end

local function compact_sse(raw, truncated)
    local state = parse_sse(raw, truncated)
    if not state then
        return nil
    end
    return compact_state(state, truncated)
end

local function compact_sse_parts(raw, truncated)
    local state = parse_sse(raw, truncated)
    if not state then
        return nil
    end
    return compact_state_parts(state, truncated)
end

function _M.compact(raw, content_type, mode, truncated)
    raw = sanitize(tostring(raw or ""))
    if mode == "raw" then
        return raw .. (truncated and "[truncated]" or "")
    end

    if raw:find("^data:") or tostring(content_type):find("text/event-stream", 1, true) then
        local compacted = compact_sse(raw, truncated)
        if compacted then
            return compacted
        end
    end

    if not truncated then
        local decoded = cjson.decode(raw)
        if decoded ~= nil then
            return compact_model_list(decoded) or cjson.encode(decoded) or compact_fallback(raw, false)
        end
    end
    return compact_fallback(raw, truncated)
end

function _M.compact_parts(raw, content_type, mode, truncated)
    raw = sanitize(tostring(raw or ""))
    if mode ~= "raw"
        and (raw:find("^data:") or tostring(content_type):find("text/event-stream", 1, true))
    then
        local parts = compact_sse_parts(raw, truncated)
        if parts then
            return parts
        end
    end
    return { _M.compact(raw, content_type, mode, truncated) }
end

function _M.compact_request(raw, mode)
    raw = sanitize(tostring(raw or ""))
    if raw == "" then
        return ""
    end
    local decoded = cjson.decode(raw)
    if decoded == nil then
        return "[unparseable request body omitted]"
    end

    local redacted = redact_sensitive(decoded)
    local encoded = cjson.encode(redacted)
    if not encoded then
        return "[unencodable request body omitted]"
    end
    if mode == "raw" then
        return encoded
    end
    return compact_request_body(redacted, #raw) or "[unencodable request body omitted]"
end

local function stream_result(state, complete, interrupted)
    local result = {
        chunk = state.chunk,
        complete = complete,
    }
    if #state.segments == 1 then
        local segment = state.segments[1]
        if segment.kind == "content" then
            result.content = segment.text
        elseif segment.kind == "reasoning" then
            result.reasoning = segment.text
        elseif segment.kind == "tool_call" then
            result.tool_calls = { segment.tool_call }
        else
            result[segment.kind] = segment.text
        end
    elseif #state.segments > 1 then
        result.segments = state.segments
    end
    if state.finish_reason ~= nil then
        result.finish_reason = state.finish_reason
    end
    if state.usage ~= nil then
        result.usage = state.usage
    end
    if interrupted then
        result.interrupted = true
        result.truncated = true
    end
    return result
end

local function reset_segments(state)
    state.segments = {}
    state.segment_bytes = 0
end

local function emit_segments(state)
    if #state.segments == 0 then
        return
    end
    local encoded = assert(cjson.encode(stream_result(state, false, false)))
    local ok, err = require("audit_access").emit_chunk(encoded, state.chunk)
    if not ok then
        error("streaming audit failed closed: " .. tostring(err))
    end
    state.chunk = state.chunk + 1
    reset_segments(state)
end

local function bounded_metadata(value)
    return truncate_utf8(sanitize(tostring(value or "")), 256)
end

local function append_segment(state, kind, value, tool_call)
    value = sanitize(tostring(value or ""))
    repeat
        if state.segment_bytes >= MAX_COMPACT_TEXT_BYTES
            or #state.segments >= MAX_STREAM_SEGMENTS
        then
            emit_segments(state)
        end

        local available = MAX_COMPACT_TEXT_BYTES - state.segment_bytes
        local part = truncate_utf8(value, available)
        local previous = state.segments[#state.segments]
        local tool_key = tool_call and tool_call.index or nil
        local can_merge = previous and previous.kind == kind
            and (kind ~= "tool_call" or previous.tool_call.index == tool_key)
        if can_merge then
            if kind == "tool_call" then
                previous.tool_call.arguments = previous.tool_call.arguments .. part
                previous.tool_call.id = previous.tool_call.id ~= "" and previous.tool_call.id
                    or bounded_metadata(tool_call.id)
                previous.tool_call.name = previous.tool_call.name ~= "" and previous.tool_call.name
                    or bounded_metadata(tool_call.name)
            else
                previous.text = previous.text .. part
            end
        elseif kind == "tool_call" then
            state.segments[#state.segments + 1] = {
                kind = kind,
                tool_call = {
                    index = bounded_metadata(tool_key),
                    id = bounded_metadata(tool_call.id),
                    type = bounded_metadata(tool_call.type),
                    name = bounded_metadata(tool_call.name),
                    arguments = part,
                },
            }
        else
            state.segments[#state.segments + 1] = { kind = kind, text = part }
        end
        state.segment_bytes = state.segment_bytes + #part
        value = value:sub(#part + 1)
        if state.segment_bytes >= MAX_COMPACT_TEXT_BYTES then
            emit_segments(state)
        end
    until value == ""
end

local function append_event_state(state, event_state)
    for _, value in ipairs(event_state.content) do
        append_segment(state, "content", value)
    end
    for _, value in ipairs(event_state.reasoning) do
        append_segment(state, "reasoning", value)
    end
    for _, key in ipairs(event_state.tool_order) do
        local call = event_state.tool_calls[key]
        append_segment(state, "tool_call", call.arguments, {
            index = key,
            id = call.id,
            type = call.type,
            name = call.name,
        })
    end
    state.finish_reason = event_state.finish_reason or state.finish_reason
    state.usage = event_state.usage or state.usage
end

local function consume_sse_event(state, event)
    local data_lines = {}
    event = event:gsub("\r\n", "\n")
    for line in (event .. "\n"):gmatch("(.-)\n") do
        local data = line:match("^data:%s?(.*)$")
        if data then
            data_lines[#data_lines + 1] = data
        end
    end
    if #data_lines == 0 then
        return
    end

    local data = table.concat(data_lines, "\n")
    if data == "[DONE]" then
        state.saw_done = true
        return
    end

    local payload = cjson.decode(data)
    local event_state = { content = {}, reasoning = {}, tool_calls = {}, tool_order = {} }
    if type(payload) == "table" and consume_payload(event_state, payload) then
        append_event_state(state, event_state)
        return
    end
    append_segment(state, "unparsed_sse_payload", data)
end

local function event_boundary(value)
    local lf_start, lf_end = value:find("\n\n", 1, true)
    local crlf_start, crlf_end = value:find("\r\n\r\n", 1, true)
    if crlf_start and (not lf_start or crlf_start < lf_start) then
        return crlf_start, crlf_end
    end
    return lf_start, lf_end
end

local function capture_sse(state, chunk)
    state.pending = state.pending .. chunk
    while true do
        local boundary_start, boundary_end = event_boundary(state.pending)
        if boundary_start and boundary_start <= MAX_PENDING_EVENT_BYTES then
            local event = state.pending:sub(1, boundary_start - 1)
            if state.oversized_event then
                append_segment(state, "unparsed_sse_fragment", event)
            else
                consume_sse_event(state, event)
            end
            state.pending = state.pending:sub(boundary_end + 1)
            state.oversized_event = false
        elseif #state.pending > MAX_PENDING_EVENT_BYTES then
            local fragment = truncate_utf8(state.pending, MAX_COMPACT_TEXT_BYTES)
            state.pending = state.pending:sub(#fragment + 1)
            if not state.oversized_event then
                fragment = fragment:gsub("^data:%s?", "")
            end
            append_segment(state, "unparsed_sse_fragment", fragment)
            state.oversized_event = true
        else
            break
        end
    end
end

local function response_state()
    local state = ngx.ctx.audit_stream_state
    if state then
        return state
    end
    state = {
        chunk = 1,
        content_type = tostring(ngx.header.content_type or ""),
        mode = os.getenv("AUDIT_LOG_MODE") or "compact",
        pending = "",
        segments = {},
        segment_bytes = 0,
        buffer = "",
    }
    ngx.ctx.audit_stream_state = state
    return state
end

function _M.capture(chunk, finished)
    local state = response_state()
    if type(chunk) == "string" and chunk ~= "" then
        state.had_body = true
        local is_sse = state.content_type:find("text/event-stream", 1, true) ~= nil
        if state.mode == "raw" then
            append_segment(state, "raw", chunk)
        elseif is_sse then
            capture_sse(state, chunk)
        elseif state.streaming_body then
            append_segment(state, "body", chunk)
        else
            state.buffer = state.buffer .. chunk
            if #state.buffer > MAX_PENDING_EVENT_BYTES then
                state.streaming_body = true
                append_segment(state, "body", state.buffer)
                state.buffer = ""
            end
        end
    end

    if finished then
        _M.finalize(false)
    end
end

function _M.finalize(interrupted)
    if ngx.ctx.audit_response_finalized then
        return
    end

    ngx.ctx.audit_response_interrupted = interrupted == true
    local state = response_state()
    if not state.had_body and interrupted then
        ngx.var.resp_body = "[response interrupted before completion]"
    elseif state.mode ~= "raw"
        and not state.streaming_body
        and not state.content_type:find("text/event-stream", 1, true)
    then
        ngx.var.resp_body = _M.compact(state.buffer, state.content_type, state.mode, interrupted)
    else
        if state.pending ~= "" then
            local pending = state.pending:gsub("^data:%s?", "")
            append_segment(state, "unparsed_sse_payload", pending)
            state.pending = ""
        end
        ngx.var.resp_body = assert(cjson.encode(stream_result(state, not interrupted, interrupted)))
    end
    ngx.ctx.audit_response_finalized = true
end

return _M