local cjson = require("cjson.safe")

local _M = {}

local function ordered_json(fields)
    local parts = {}
    for _, pair in ipairs(fields) do
        parts[#parts + 1] = cjson.encode(pair[1]) .. ":" .. cjson.encode(pair[2])
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

local function encode_or_fallback(fields)
    local ok, result = pcall(ordered_json, fields)
    if ok and result then
        return result
    end
    return "{}"
end

local function bounded_value(value, encoded_limit)
    local text = tostring(value or "")
    local encoded = cjson.encode(text)
    if encoded and #encoded <= encoded_limit then
        return text
    end

    local suffix = "[truncated]"
    local low = 0
    local high = #text
    local result = suffix
    while low <= high do
        local middle = math.floor((low + high) / 2)
        local candidate = string.sub(text, 1, middle) .. suffix
        local candidate_encoded = cjson.encode(candidate)
        if candidate_encoded and #candidate_encoded <= encoded_limit then
            result = candidate
            low = middle + 1
        else
            high = middle - 1
        end
    end
    return result
end

local function header(headers, name)
    return headers[name] or headers[name:lower()]
end

local function first_nonempty(...)
    for index = 1, select("#", ...) do
        local value = select(index, ...)
        if value ~= nil and tostring(value) ~= "" then
            return value
        end
    end
    return nil
end

local function decode_jwt_user(auth_header)
    if type(auth_header) ~= "string" then
        return nil
    end

    local token = auth_header:match("^Bearer%s+(.+)$")
    local payload = token and token:match("^[^.]+%.([^.]+)%.[^.]+$")
    if not payload then
        return nil
    end

    payload = payload:gsub("-", "+"):gsub("_", "/")
    local remainder = #payload % 4
    if remainder > 0 then
        payload = payload .. string.rep("=", 4 - remainder)
    end

    local decoded = ngx.decode_base64(payload)
    local claims = decoded and cjson.decode(decoded)
    if type(claims) ~= "table" then
        return nil
    end
    return claims.sub or claims.email
end

function _M.resolve_identity(request_id)
    local context = ngx.ctx or {}
    local var = ngx.var or {}
    local headers = {}
    if ngx.req and ngx.req.get_headers then
        headers = ngx.req.get_headers() or {}
    end

    local resolved_request_id = first_nonempty(
        request_id,
        context.request_id,
        var.provost_req_id,
        var.request_id
    ) or ""
    local is_mcp_path = context.is_mcp_path or (var.uri or ""):match("^/mcp/") ~= nil
    local user_id = context.user_id
    if not user_id or user_id == "" then
        if is_mcp_path then
            user_id = header(headers, "X-Cognito-User")
        else
            user_id = decode_jwt_user(header(headers, "Authorization"))
        end
    end
    user_id = first_nonempty(user_id, var.provost_user_id, "steve")

    local body = var.req_body or ""
    local parsed = is_mcp_path and cjson.decode(body) or nil
    local arguments = type(parsed) == "table"
        and type(parsed.params) == "table"
        and type(parsed.params.arguments) == "table"
        and parsed.params.arguments
        or nil
    local body_customer_id = arguments
        and first_nonempty(arguments.customer_id, arguments.customer_name)
        or nil
    local customer_id = first_nonempty(
        context.customer_id,
        body_customer_id,
        var.provost_customer_id,
        "craig"
    )

    local conversation_id = first_nonempty(
        context.conversation_id,
        header(headers, "X-Conversation-Id"),
        var.provost_conversation_id,
        "none"
    )

    if is_mcp_path and arguments and not context.tool_name then
        context.tool_name = parsed.params.name
    end

    if ngx.var then
        ngx.var.provost_req_id = resolved_request_id
        ngx.var.provost_user_id = tostring(user_id)
        ngx.var.provost_customer_id = tostring(customer_id)
        ngx.var.provost_conversation_id = tostring(conversation_id)
    end

    return resolved_request_id, tostring(user_id), tostring(customer_id), tostring(conversation_id)
end

function _M.emit(tag, status_code, error_code, error_detail, opts)
    opts = opts or {}
    local request_id, user_id, customer_id, conversation_id =
        _M.resolve_identity(opts.request_id)

    local fields = {
        {"time_local", bounded_value(ngx.var.time_local, 64)},
        {"remote_addr", bounded_value(ngx.var.remote_addr, 64)},
        {"request", bounded_value(ngx.var.request, 256)},
        {"status", bounded_value(status_code or ngx.status, 16)},
        {"request_id", bounded_value(request_id, 96)},
        {"user_id", bounded_value(user_id, 96)},
        {"customer_id", bounded_value(customer_id, 96)},
        {"conversation_id", bounded_value(conversation_id, 96)},
        {"request_body", bounded_value(opts.request_body or ngx.var.req_body, 512)},
        {"resp_body", bounded_value(opts.resp_body or ngx.var.resp_body, 512)},
        {"error_code", bounded_value(error_code or "PROVOST_ERROR", 96)},
        {"error_detail", bounded_value(error_detail, 256)},
        {"stream_tag", bounded_value(tag, 96)},
        {"log_type", "error"},
        {"date", bounded_value(ngx.utctime(), 64)},
    }

    if ngx.ctx and ngx.ctx.is_mcp_path then
        table.insert(fields, 9, {"tool_name", bounded_value(ngx.ctx.tool_name, 96)})
        table.insert(fields, 10, {"destination", bounded_value(ngx.ctx.mcp_destination, 256)})
    end

    local encoded = encode_or_fallback(fields)
    ngx.log(ngx.ERR, "PROVOST_AUDIT_ERROR " .. encoded)
end

return _M