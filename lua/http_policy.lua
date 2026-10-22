local cjson = require("cjson.safe")
local audit_body = require("audit_body")
local audit_error = require("audit_error")
local governance_rejection = require("governance_rejection")
local llm_aggregate = require("llm_aggregate")
local routes = require("routes")
local rules_engine = require("rules_engine")

local MAX_REQUEST_BYTES = 1048576
local llm_routes_json = os.getenv("LLM_ROUTES_JSON")
local llm_routes = cjson.decode(llm_routes_json or "")

if type(llm_routes) ~= "table" then
    llm_routes = nil
end

local function header(headers, name)
    return headers[name] or headers[name:lower()]
end

local function read_secret_file(path)
    local file = io.open(path, "r")
    if not file then
        return nil
    end
    local value = file:read("*a")
    file:close()
    if type(value) ~= "string" then
        return nil
    end
    value = value:gsub("[\r\n]+$", "")
    return value ~= "" and value or nil
end

local function expected_provost_token()
    local cached = ngx.shared.provost_secrets and ngx.shared.provost_secrets:get("token")
    if cached and cached ~= "" then
        return cached
    end
    local token = os.getenv("PROVOST_TOKEN") or read_secret_file("/run/secrets/provost_token")
    if token and ngx.shared.provost_secrets then
        ngx.shared.provost_secrets:set("token", token)
    end
    return token
end

local function valid_provost_token(headers)
    local expected = expected_provost_token()
    if not expected then
        return false, "Provost token is not configured"
    end

    local provided = header(headers, "X-Provost-Token") or ngx.var.http_x_provost_token
    if not provided or provided == "" then
        local authorization = header(headers, "Authorization") or ngx.var.http_authorization
        if type(authorization) == "string" then
            provided = authorization:match("^[Bb][Ee][Aa][Rr][Ee][Rr]%s+(.+)$")
        end
    end
    if type(provided) == "string" then
        provided = provided:gsub("[\r\n]+$", "")
    end
    if provided ~= expected then
        return false, "Invalid Provost token"
    end
    return true
end

local function decode_jwt_user(auth_header)
    if type(auth_header) ~= "string" then
        return nil
    end

    local token = auth_header:match("^Bearer%s+(.+)$")
    if not token then
        return nil
    end

    local payload = token:match("^[^.]+%.([^.]+)%.[^.]+$")
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

local function read_rules()
    local raw = ngx.shared.rules and ngx.shared.rules:get("rules")
    local rules = raw and cjson.decode(raw)
    if type(rules) ~= "table" then
        return {}
    end
    return rules
end

local function read_request_body()
    ngx.req.read_body()
    local body = ngx.req.get_body_data()
    if body then
        return body
    end

    local body_file = ngx.req.get_body_file and ngx.req.get_body_file()
    if not body_file then
        return ""
    end

    local file, open_error = io.open(body_file, "rb")
    if not file then
        return nil, "unable to read buffered request body: " .. (open_error or "unknown")
    end
    body = file:read(MAX_REQUEST_BYTES + 1)
    file:close()
    if not body then
        return nil, "unable to read buffered request body"
    end
    if #body > MAX_REQUEST_BYTES then
        return nil, "request body exceeds capture limit"
    end
    return body
end

local function reject(reason, status, error_code)
    status = status or ngx.HTTP_FORBIDDEN
    error_code = error_code or "PROVOST_INTERVENTION"
    if status == ngx.HTTP_FORBIDDEN then
        return governance_rejection.reject(
            ngx,
            status,
            error_code,
            reason,
            "provost_llm_to_mcp_error"
        )
    end
    local response_body = cjson.encode({
        error = "Request processing failed",
        reason = reason,
    })
    ngx.var.resp_body = response_body
    audit_error.emit(
        "provost_request_error",
        status,
        error_code,
        reason,
        { resp_body = response_body }
    )
    ngx.status = status
    ngx.header["Content-Type"] = "application/json"
    ngx.say(response_body)
    return ngx.exit(status)
end

local function reject_route(reason, status, error_code)
    local response_body = cjson.encode({ error = reason })
    ngx.var.resp_body = response_body
    audit_error.emit("provost_request_error", status, error_code, reason, {
        resp_body = response_body,
    })
    ngx.status = status
    ngx.header["Content-Type"] = "application/json"
    ngx.say(response_body)
    return ngx.exit(status)
end

local headers = ngx.req.get_headers()
local uri = ngx.var.uri or ""
local is_mcp_path = uri:match("^/mcp/") ~= nil
-- Aggregate /llm/v1/*: the backend comes from the body's model prefix.
local aggregate_path = not is_mcp_path and uri:match("^/llm/v1(/.*)$") or nil
local aggregate

if is_mcp_path then
    local authenticated, auth_error = valid_provost_token(headers)
    if not authenticated then
        return reject_route(auth_error, ngx.HTTP_UNAUTHORIZED, "PROVOST_TOKEN_INVALID")
    end
end

local user_id = header(headers, "X-Cognito-User")
if type(user_id) ~= "string" or user_id == "" then
    user_id = decode_jwt_user(header(headers, "Authorization"))
end
if type(user_id) ~= "string" or user_id == "" then
    user_id = "steve"
end

local conversation_id = header(headers, "X-Conversation-Id")
if type(conversation_id) ~= "string" or conversation_id == "" then
    conversation_id = "none"
end

ngx.ctx.user_id = user_id
ngx.ctx.customer_id = "craig"
ngx.ctx.conversation_id = conversation_id
ngx.ctx.is_mcp_path = is_mcp_path
ngx.var.provost_req_id = ngx.var.request_id or ""
ngx.var.provost_user_id = user_id
ngx.var.provost_customer_id = "craig"
ngx.var.provost_conversation_id = conversation_id

if is_mcp_path then
    local server_name = uri:match("^/mcp/([^/]+)")
    if server_name then
        local destination = routes.get(server_name)
        ngx.ctx.mcp_server_name = server_name
        ngx.ctx.mcp_destination = destination or ""
    end
end

local body, body_error = read_request_body()
if not body then
    ngx.var.req_body = ""
    return reject(body_error, ngx.HTTP_INTERNAL_SERVER_ERROR, "REQUEST_BODY_READ_ERROR")
end
ngx.var.req_body = audit_body.compact_request(body, os.getenv("AUDIT_LOG_MODE") or "compact")
ngx.ctx.request_body = body
local customer_id = "craig"
local parsed = is_mcp_path and cjson.decode(body) or nil
if type(parsed) == "table"
   and parsed.method == "tools/call"
   and type(parsed.params) == "table"
   and type(parsed.params.arguments) == "table" then
    local arguments = parsed.params.arguments
    customer_id = arguments.customer_id or arguments.customer_name or customer_id
    ngx.ctx.tool_name = parsed.params.name
end
if type(customer_id) ~= "string" and type(customer_id) ~= "number" then
    customer_id = "craig"
end
customer_id = tostring(customer_id)

ngx.ctx.user_id = user_id
ngx.ctx.customer_id = customer_id
ngx.var.provost_customer_id = customer_id

-- The aggregate listing has no single backend; llm_models.lua fans out.
if not is_mcp_path and aggregate_path ~= "/models" then
    if not llm_routes then
        return reject_route(
            "LLM backend routing is not configured",
            ngx.HTTP_INTERNAL_SERVER_ERROR,
            "LLM_ROUTES_INVALID"
        )
    end

    local backend_name = ngx.var.backend_name
    if not backend_name and uri == "/llm/bedrock/v1/models" then
        backend_name = "bedrock"
    end
    if aggregate_path then
        local resolved, status, error_code, message = llm_aggregate.resolve(body, llm_routes)
        if not resolved then
            return llm_aggregate.reject(status, error_code, message)
        end
        aggregate = resolved
        backend_name = resolved.backend
    end
    local backend_url = backend_name and llm_routes[backend_name]
    if type(backend_url) ~= "string" then
        return reject_route(
            "Unknown LLM backend: " .. (backend_name or ""),
            ngx.HTTP_NOT_FOUND,
            "LLM_BACKEND_UNKNOWN"
        )
    end
    if not backend_url:match("^https?://[^%s/#@]+[^%s#@]*$") then
        return reject_route(
            "LLM backend routing is not configured",
            ngx.HTTP_INTERNAL_SERVER_ERROR,
            "LLM_ROUTE_INVALID"
        )
    end

    local backend_path = aggregate_path or uri:match("^/llm/[^/]+/v1(.*)$")
    if backend_path == nil then
        return reject_route("Invalid LLM backend path", ngx.HTTP_NOT_FOUND, "LLM_PATH_INVALID")
    end
    if backend_name == "bedrock" then
        if os.getenv("BEDROCK_ENABLED") ~= "true" then
            return reject_route("Bedrock backend is disabled", ngx.HTTP_NOT_FOUND, "BEDROCK_DISABLED")
        end
        -- Bedrock is reached through the native Converse API; the OpenAI
        -- request is translated after rules and audit have seen it.
        if backend_path ~= "/chat/completions" and backend_path ~= "/models" then
            return reject_route(
                "Bedrock supports only /chat/completions and /models",
                ngx.HTTP_NOT_FOUND,
                "BEDROCK_PATH_UNSUPPORTED"
            )
        end
        ngx.var.bedrock_path = backend_path
    else
        ngx.var.llm_target_url = backend_url:gsub("/$", "") .. backend_path
    end
end

local allowed, reason, redacted_body = rules_engine.check_request(
    ngx.req.get_method(),
    uri,
    body,
    read_rules(),
    {
        user_id = user_id,
        customer_id = customer_id,
        conversation_id = conversation_id,
        is_mcp_path = is_mcp_path,
        mcp_server_name = ngx.ctx.mcp_server_name,
        store = ngx.shared.provost_ctx,
    }
)

if not allowed then
    return reject(reason)
end

if not is_mcp_path then
    redacted_body = type(redacted_body) == "string" and redacted_body or body
    if redacted_body ~= body then
        ngx.req.set_body_data(redacted_body)
        ngx.var.req_body_original = audit_body.compact_request(
            body,
            os.getenv("AUDIT_LOG_MODE") or "compact"
        )
    end
    body = redacted_body
    ngx.var.req_body = audit_body.compact_request(
        body,
        os.getenv("AUDIT_LOG_MODE") or "compact"
    )
end

if aggregate then
    if not llm_aggregate.ensure_available(aggregate.backend, llm_routes[aggregate.backend]) then
        return llm_aggregate.reject(
            ngx.HTTP_SERVICE_UNAVAILABLE,
            "PROVOST_BACKEND_DOWN",
            "LLM backend " .. aggregate.backend .. " is unavailable"
        )
    end
    llm_aggregate.apply_backend_key(aggregate.backend)
    -- req_body above keeps the prefixed id the user selected; only the
    -- upstream copy carries the stripped id.
    body = llm_aggregate.strip_model(body, aggregate)
    ngx.req.set_body_data(body)
    ngx.ctx.llm_aggregate = aggregate
end

if not is_mcp_path and (ngx.var.backend_name == "bedrock"
    or (aggregate and aggregate.backend == "bedrock")) then
    local translated, translate_error = nil, nil
    if ngx.var.bedrock_path == "/chat/completions" then
        translated, translate_error = require("bedrock_converse").translate_request(body)
        if not translated then
            return reject_route(translate_error, ngx.HTTP_BAD_REQUEST, "BEDROCK_REQUEST_INVALID")
        end
        local model_allowed, model_error, model_status, model_code =
            require("bedrock").check_model(translated.state.model)
        if not model_allowed then
            return reject_route(model_error, model_status or ngx.HTTP_FORBIDDEN,
                model_code or "BEDROCK_MODEL_NOT_ALLOWED")
        end
        body = translated.body
        ngx.req.set_body_data(body)
        ngx.req.set_header("Content-Type", "application/json")
        ngx.req.set_header("Accept", translated.state.stream and "application/vnd.amazon.eventstream"
            or "application/json")
        ngx.var.bedrock_path = translated.path
        ngx.ctx.bedrock_converse = translated.state
    end
    local host, signing_error = require("bedrock").prepare_request(body, ngx.var.bedrock_path)
    if not host then
        return reject_route(
            "Bedrock authentication is unavailable",
            ngx.HTTP_SERVICE_UNAVAILABLE,
            "BEDROCK_AUTH_UNAVAILABLE"
        )
    end
    ngx.var.llm_target_url = "https://" .. host .. ngx.var.bedrock_path
end

-- Persist the 4-layer identity so the outbound MCP-to-API hop (port 8081)
-- can restore it even when the MCP server strips provost headers.
if is_mcp_path then
    require("outbound_identity").store(
        ngx.var.provost_req_id,
        user_id,
        customer_id,
        conversation_id
    )
end