local cjson = require("cjson.safe")
local rules_engine = require("rules_engine")

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

local function reject(reason)
    ngx.status = ngx.HTTP_FORBIDDEN
    ngx.header["Content-Type"] = "application/json"
    ngx.say(cjson.encode({
        error = "Governance rule violation",
        reason = reason,
    }))
    return ngx.exit(ngx.HTTP_FORBIDDEN)
end

local headers = ngx.req.get_headers()
local uri = ngx.var.uri or ""
local is_mcp_path = uri:match("^/mcp/") ~= nil

local user_id
if is_mcp_path then
    user_id = header(headers, "X-Cognito-User")
else
    user_id = decode_jwt_user(header(headers, "Authorization"))
end
if type(user_id) ~= "string" or user_id == "" then
    user_id = "steve"
end

local conversation_id = header(headers, "X-Conversation-Id")
if type(conversation_id) ~= "string" or conversation_id == "" then
    conversation_id = "none"
end

ngx.req.read_body()
local body = ngx.req.get_body_data() or ""
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
ngx.ctx.conversation_id = conversation_id
ngx.ctx.is_mcp_path = is_mcp_path
ngx.var.provost_user_id = user_id
ngx.var.provost_customer_id = customer_id
ngx.var.provost_conversation_id = conversation_id

if not is_mcp_path then
    ngx.var.llm_target_url = os.getenv("LLM_API_URL") or "https://api.openai.com"
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