local cjson = require("cjson.safe")

-- WSO2 strips correlation headers; never attribute its REST calls to the
-- globally last-seen user, which may belong to another concurrent request.
require("outbound_identity").resolve(false)

local function reject(status, message)
    ngx.status = status
    ngx.header["Content-Type"] = "application/json"
    ngx.say(cjson.encode({ error = message }))
    return ngx.exit(status)
end

-- Enforce read-only on the REST hop too, even if an MCP tool bypasses policy.
local method = ngx.req.get_method()
if method ~= "GET" and method ~= "HEAD" then
    return reject(ngx.HTTP_FORBIDDEN, "FHIR is read-only: write requests are forbidden")
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
