local cjson = require("cjson.safe")

local _M = {}

local function enabled_params(rule)
    if type(rule) ~= "table" or rule.enabled == false then
        return nil
    end

    if type(rule.params) == "table" then
        return rule.params
    end

    return rule
end

local function contains(values, expected)
    if type(values) ~= "table" then
        return false
    end

    for _, value in ipairs(values) do
        if value == expected then
            return true
        end
    end

    return false
end

local function outside_allowed_hours(allowed_hours)
    if type(allowed_hours) ~= "string" then
        return false
    end

    local start_hour, start_minute, end_hour, end_minute =
        allowed_hours:match("^(%d%d):(%d%d)%-(%d%d):(%d%d)$")
    if not start_hour then
        return false
    end

    local start_total = tonumber(start_hour) * 60 + tonumber(start_minute)
    local end_total = tonumber(end_hour) * 60 + tonumber(end_minute)
    local now = os.date("!*t")
    local current_total = now.hour * 60 + now.min

    if start_total <= end_total then
        return current_total < start_total or current_total > end_total
    end

    return current_total > end_total and current_total < start_total
end

function _M.parse_mcp_request(body)
    if type(body) ~= "string" or body == "" then
        return nil
    end

    local parsed = cjson.decode(body)
    if type(parsed) ~= "table" then
        return nil
    end

    local tool_name
    local arguments
    if parsed.method == "tools/call" and type(parsed.params) == "table" then
        if type(parsed.params.name) == "string" then
            tool_name = parsed.params.name
        end
        arguments = parsed.params.arguments
    end

    return {
        method = parsed.method,
        tool_name = tool_name,
        arguments = arguments,
        id = parsed.id,
    }
end

local function check_allowlist(rules, tool_name)
    local params = enabled_params(rules.tool_allowlist)
    if not params or type(params.tools) ~= "table" or #params.tools == 0 then
        return true
    end

    if contains(params.tools, tool_name) then
        return true
    end

    return false, "tool not in allowlist: " .. (tool_name or "unknown")
end

local function check_blocklist(rules, tool_name)
    local params = enabled_params(rules.tool_blocklist)
    if not params or not contains(params.tools, tool_name) then
        return true
    end

    return false, "tool is blocked: " .. tool_name
end

local function check_rate_limit(rules, tool_name, context)
    local params = enabled_params(rules.rate_limits)
    local rule = params and params.rules and params.rules[tool_name]
    if type(rule) ~= "table" then
        return true
    end

    local rate_limit = require("rate_limit")
    local exceeded = rate_limit.is_tool_rate_exceeded(
        tool_name,
        context.user_id,
        rule.max_calls,
        rule.window_seconds
    )
    if not exceeded then
        return true
    end

    return false, "rate limit exceeded for tool: " .. tool_name
end

local function check_token_cap(rules, arguments)
    local params = enabled_params(rules.token_caps)
    if not params or type(arguments) ~= "table" then
        return true
    end

    local requested = tonumber(arguments.max_tokens)
    local maximum = tonumber(params.max_tokens)
    if not requested or not maximum or requested <= maximum then
        return true
    end

    return false, "token cap exceeded: requested " .. requested .. ", max " .. maximum
end

local function check_time_rules(rules, tool_name)
    local params = enabled_params(rules.time_based_rules)
    if not params or type(params.rules) ~= "table" then
        return true
    end

    for _, rule in ipairs(params.rules) do
        if rule.tool == tool_name and outside_allowed_hours(rule.allowed_hours) then
            return false, "tool not allowed outside hours: " .. rule.allowed_hours
        end
    end

    return true
end

function _M.check_request(method, uri, body, rules, context)
    rules = type(rules) == "table" and rules or {}
    context = type(context) == "table" and context or {}

    if not context.is_mcp_path then
        return true, "chat path allowed"
    end

    local request = _M.parse_mcp_request(body)
    if not request then
        return true, "non-JSON body, allowing"
    end

    if request.method ~= "tools/call" then
        return true, "non-tool MCP request, allowing"
    end

    local allowed, reason = check_allowlist(rules, request.tool_name)
    if not allowed then
        return false, reason
    end

    allowed, reason = check_blocklist(rules, request.tool_name)
    if not allowed then
        return false, reason
    end

    allowed, reason = check_rate_limit(rules, request.tool_name, context)
    if not allowed then
        return false, reason
    end

    allowed, reason = check_token_cap(rules, request.arguments)
    if not allowed then
        return false, reason
    end

    return check_time_rules(rules, request.tool_name)
end

return _M