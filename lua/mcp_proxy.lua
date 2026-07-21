local cjson = require("cjson.safe")
local http = require("resty.http")

local function get_mcp_url(server_name)
    local path = os.getenv("MCP_ROUTING_TABLE_PATH") or "/etc/nginx/mcp_routes.json"
    local file, open_error = io.open(path, "r")
    if not file then
        return nil, "routing table not found at " .. path .. ": " .. (open_error or "unknown")
    end

    local content = file:read("*a")
    file:close()
    local routes = cjson.decode(content)
    if type(routes) ~= "table" then
        return nil, "invalid routing table JSON"
    end

    local destination = routes[server_name]
    if type(destination) ~= "string" or destination == "" then
        return nil, "server '" .. server_name .. "' not found in routing table"
    end
    if not destination:match("^https?://") then
        return nil, "server destination must use HTTP or HTTPS"
    end

    return destination:gsub("/$", "")
end

local function respond(status, payload)
    ngx.status = status
    ngx.header["Content-Type"] = "application/json"
    ngx.say(cjson.encode(payload))
    return ngx.exit(status)
end

local uri = ngx.var.uri or ""
local server_name = uri:match("^/mcp/([^/]+)")
if not server_name then
    return respond(ngx.HTTP_BAD_REQUEST, { error = "Invalid MCP path" })
end

local destination, route_error = get_mcp_url(server_name)
if not destination then
    return respond(ngx.HTTP_BAD_GATEWAY, {
        error = "MCP server not found",
        server = server_name,
        reason = route_error,
    })
end

ngx.ctx.mcp_server_name = server_name
ngx.ctx.mcp_destination = destination
ngx.ctx.is_mcp_path = true

local remaining_path = uri:gsub("^/mcp/[^/]+", "", 1)
if remaining_path == "" then
    remaining_path = "/"
end
local target_url = destination .. remaining_path
if ngx.var.is_args == "?" and ngx.var.args then
    target_url = target_url .. "?" .. ngx.var.args
end

ngx.req.read_body()
local headers = ngx.req.get_headers()
headers.host = nil
headers.Host = nil
headers["content-length"] = nil
headers["Content-Length"] = nil

local client = http.new()
client:set_timeout(30000)
local response, request_error = client:request_uri(target_url, {
    method = ngx.req.get_method(),
    body = ngx.req.get_body_data(),
    headers = headers,
    ssl_verify = true,
})
if not response then
    return respond(ngx.HTTP_BAD_GATEWAY, {
        error = "Failed to connect to MCP server",
        server = server_name,
        reason = request_error,
    })
end

ngx.status = response.status
for name, value in pairs(response.headers) do
    local lower_name = name:lower()
    if lower_name ~= "connection"
       and lower_name ~= "content-length"
       and lower_name ~= "transfer-encoding" then
        ngx.header[name] = value
    end
end
ngx.print(response.body or "")

return nil