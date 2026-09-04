local cjson = require("cjson.safe")
local http = require("resty.http")
local routes = require("routes")

local ALPACA_PORTFOLIO_TOOLS = {
    get_account_info = true,
    get_all_positions = true,
    get_open_position = true,
    get_portfolio_history = true,
}

local function filter_alpaca_tools(server_name, request_body, response_body)
    if server_name ~= "alpaca" then
        return response_body
    end

    local request = cjson.decode(request_body)
    if type(request) ~= "table" or request.method ~= "tools/list" then
        return response_body
    end

    local function filter_payload(payload)
        local response = cjson.decode(payload)
        if type(response) ~= "table"
           or type(response.result) ~= "table"
           or type(response.result.tools) ~= "table" then
            return payload
        end

        local filtered_tools = {}
        for _, tool in ipairs(response.result.tools) do
            if type(tool) == "table"
               and ALPACA_PORTFOLIO_TOOLS[tool.name] then
                filtered_tools[#filtered_tools + 1] = tool
            end
        end
        response.result.tools = filtered_tools
        return cjson.encode(response)
    end

    local event_prefix = "event: message\r\ndata: "
    local event_start, payload_start = response_body:find(event_prefix, 1, true)
    if event_start then
        local payload_end = response_body:find("\r\n\r\n", payload_start + 1, true)
        if payload_end then
            local payload = response_body:sub(payload_start + 1, payload_end - 1)
            return response_body:sub(1, payload_start) .. filter_payload(payload)
                .. response_body:sub(payload_end)
        end
    end

    return filter_payload(response_body)
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

local destination, route_error = routes.get(server_name)
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
local target_url = destination
if remaining_path ~= "/" or not destination:match("/mcp$") then
    target_url = destination .. remaining_path
end
if ngx.var.is_args == "?" and ngx.var.args then
    target_url = target_url .. "?" .. ngx.var.args
end

local request_body = ngx.ctx.request_body
if type(request_body) ~= "string" then
    return respond(ngx.HTTP_INTERNAL_SERVER_ERROR, {
        error = "Request body unavailable",
    })
end
ngx.var.req_body = request_body
local headers = ngx.req.get_headers()
headers.host = nil
headers.Host = nil
headers["content-length"] = nil
headers["Content-Length"] = nil
headers["X-Provost-Request-Id"] = ngx.var.provost_req_id

local client = http.new()
client:set_timeout(30000)
local response, request_error = client:request_uri(target_url, {
    method = ngx.req.get_method(),
    body = request_body,
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
local response_body = filter_alpaca_tools(server_name, request_body, response.body or "")
ngx.print(response_body)
ngx.ctx.response_body = response_body
ngx.var.resp_body = response_body

return nil