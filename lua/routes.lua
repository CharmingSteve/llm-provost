local cjson = require("cjson.safe")

local _M = {}

function _M.get(server_name)
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

return _M