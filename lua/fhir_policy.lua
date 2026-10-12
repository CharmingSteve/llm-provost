local cjson = require("cjson.safe")

-- WSO2 strips correlation headers; never attribute its REST calls to the
-- globally last-seen user, which may belong to another concurrent request.
require("outbound_identity").resolve(false)

local function reject(status, message)
    if status == ngx.HTTP_FORBIDDEN then
        message = require("intervention").brand(message)
    end
    ngx.status = status
    ngx.header["Content-Type"] = "application/json"
    ngx.say(cjson.encode({ error = message }))
    return ngx.exit(status)
end

-- Resource types from rules.json mcp_servers.fhir.write_resource_allowlist.
-- Missing, disabled or unparseable rules allow no writes (fail-closed).
local function write_allowed_types()
    local raw = ngx.shared.rules and ngx.shared.rules:get("rules")
    local rules = raw and cjson.decode(raw)
    local fhir = type(rules) == "table" and type(rules.mcp_servers) == "table"
        and rules.mcp_servers.fhir
    local rule = type(fhir) == "table" and fhir.write_resource_allowlist
    if type(rule) ~= "table" or rule.enabled == false
       or type(rule.params) ~= "table" or type(rule.params.types) ~= "table" then
        return {}
    end
    return rule.params.types
end

-- Type-level write gate on the REST hop, even if an MCP tool bypasses policy.
-- Only a plain create (POST /fhir/<Type>) can pass; transactions/batches
-- (POST /fhir), instance paths and operations stay blocked. Controlled
-- substance limits are enforced in rules_engine.lua, which sees tool arguments.
local method = ngx.req.get_method()
if method ~= "GET" and method ~= "HEAD" then
    local allowed = false
    if method == "POST" then
        local path = (ngx.var.request_uri or ""):match("^/fhir([^?]*)")
        local resource_type = path and path:match("^/(%u%a*)/?$")
        if resource_type then
            for _, value in ipairs(write_allowed_types()) do
                if value == resource_type then
                    allowed = true
                    break
                end
            end
        end
    end
    if not allowed then
        return reject(ngx.HTTP_FORBIDDEN, "FHIR is read-only: write requests are forbidden")
    end
end

local base = os.getenv("FHIR_BASE_URL") or "http://hapi.fhir.org/baseR4"
base = base:gsub("/+$", "")
local authority, path = base:match("^https?://([^/?#%s]+)(.*)$")
if not authority or authority:find("@", 1, true) or path:find("[?#%s]") then
    return reject(ngx.HTTP_INTERNAL_SERVER_ERROR, "Invalid FHIR_BASE_URL configuration")
end

-- Preserve the escaped path and query without allowing callers to change host.
local request_uri = ngx.var.request_uri or ""
local boundary = request_uri:sub(6, 6)
if request_uri:sub(1, 5) ~= "/fhir"
   or (boundary ~= "" and boundary ~= "/" and boundary ~= "?") then
    return reject(ngx.HTTP_BAD_REQUEST, "Invalid FHIR request URI")
end

local suffix = request_uri:sub(6)
if suffix == "" or suffix:sub(1, 1) == "?" then
    suffix = "/" .. suffix
end
ngx.var.fhir_target_url = base .. suffix
