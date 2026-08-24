local cjson = require("cjson.safe")
local audit_error = require("audit_error")
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
    error_code = error_code or "GOVERNANCE_VIOLATION"
    local response_body = cjson.encode({
        error = status == ngx.HTTP_FORBIDDEN
            and "Governance rule violation"
            or "Request processing failed",
        reason = reason,
    })
    ngx.var.resp_body = response_body
    audit_error.emit(
        status == ngx.HTTP_FORBIDDEN and "provost_governance_error" or "provost_request_error",
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
ngx.var.req_body = body
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

if not is_mcp_path then
    if not llm_routes then
        return reject_route(
            "LLM backend routing is not configured",
            ngx.HTTP_INTERNAL_SERVER_ERROR,
            "LLM_ROUTES_INVALID"
        )
    end

    local backend_name = ngx.var.backend_name
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

    local backend_path = uri:match("^/llm/[^/]+/v1(.*)$")
    if backend_path == nil then
        return reject_route("Invalid LLM backend path", ngx.HTTP_NOT_FOUND, "LLM_PATH_INVALID")
    end
    ngx.var.llm_target_url = backend_url:gsub("/$", "") .. backend_path
end

local allowed, reason = rules_engine.check_request(
    ngx.req.get_method(),
    uri,
    body,
    read_rules(),
    {
        user_id = user_id,
        customer_id = customer_id,
        conversation_id = conversation_id,
        is_mcp_path = is_mcp_path,
    }
)

if not allowed then
    return reject(reason)
end