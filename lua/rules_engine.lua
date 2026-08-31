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

-- Built-in PII detection patterns for LLM chat prompts. Each entry can be
-- enabled via llm_rules.params.pii_block in rules.json; custom Lua patterns
-- can be added via llm_rules.params.pii_patterns.
local BUILTIN_PII_PATTERNS = {
    us_ssn = "%f[%d]%d%d%d%-%d%d%-%d%d%d%d%f[%D]",
    aws_access_key = "AKIA[%u%d][%u%d][%u%d][%u%d][%u%d][%u%d][%u%d][%u%d]"
        .. "[%u%d][%u%d][%u%d][%u%d][%u%d][%u%d][%u%d][%u%d]",
    private_key_block = "%-%-%-%-%-BEGIN[%u%s]-PRIVATE KEY%-%-%-%-%-",
    github_token = "gh[pousr]_%w%w%w%w%w%w%w%w%w%w%w%w%w%w%w%w",
}

local function check_llm_pii(params, body)
    if type(body) ~= "string" or body == "" then
        return true
    end

    if type(params.pii_block) == "table" then
        for _, name in ipairs(params.pii_block) do
            local pattern = BUILTIN_PII_PATTERNS[name]
            if pattern and body:find(pattern) then
                return false, "PII filter blocked prompt: " .. name .. " detected"
            end
        end
    end

    if type(params.pii_patterns) == "table" then
        for name, pattern in pairs(params.pii_patterns) do
            if type(pattern) == "string" then
                local matched = pcall(function()
                    return body:find(pattern)
                end) and body:find(pattern)
                if matched then
                    return false, "PII filter blocked prompt: " .. tostring(name) .. " detected"
                end
            end
        end
    end

    return true
end

local function check_llm_request(rules, body)
    local params = enabled_params(rules.llm_rules)
    if not params then
        return true, "chat path allowed"
    end

    local allowed, reason = check_llm_pii(params, body)
    if not allowed then
        return false, reason
    end

    local maximum = tonumber(params.max_tokens)
    if maximum then
        local parsed = cjson.decode(body or "")
        local requested = type(parsed) == "table" and tonumber(parsed.max_tokens)
        if requested and requested > maximum then
            return false, "token cap exceeded: requested " .. requested .. ", max " .. maximum
        end
    end

    return true, "chat path allowed"
end

-- Generic MCP rule keys that a per-server rule set may override.
local GENERIC_OVERRIDE_KEYS = {
    "tool_allowlist",
    "tool_blocklist",
    "rate_limits",
    "token_caps",
    "time_based_rules",
}

local function get_server_rules(rules, context)
    local server_name = type(context) == "table" and context.mcp_server_name
    if type(rules.mcp_servers) ~= "table"
       or type(server_name) ~= "string"
       or type(rules.mcp_servers[server_name]) ~= "table" then
        return nil
    end
    return rules.mcp_servers[server_name]
end

-- Returns the rule set with per-server overrides applied for generic keys,
-- so e.g. the Alpaca server can carry its own tool allowlist.
local function effective_rules(rules, context)
    local server_rules = get_server_rules(rules, context)
    if not server_rules then
        return rules
    end

    local merged = {}
    for key, value in pairs(rules) do
        merged[key] = value
    end
    for _, key in ipairs(GENERIC_OVERRIDE_KEYS) do
        if server_rules[key] ~= nil then
            merged[key] = server_rules[key]
        end
    end
    return merged
end

-- Per-MCP-server deterministic rules (rules.mcp_servers[<server>]), e.g.
-- trading rules for the Alpaca MCP server. Delegates to trading_rules.lua,
-- which keeps Agent Provost's block semantics.
local function check_server_rules(rules, request, context)
    local server_rules = get_server_rules(rules, context)
    if not server_rules then
        return true
    end

    local trading_rules = require("trading_rules")
    local parsed = {
        method = request.method,
        id = request.id,
        params = {
            name = request.tool_name,
            arguments = request.arguments,
        },
    }
    local trading_context = {
        user = context.user_id,
        machine = context.customer_id,
        store = context.store,
    }

    local blocked, reason = trading_rules.check_request(
        parsed,
        server_rules,
        trading_context
    )
    if blocked then
        return false, reason
    end

    return true
end

function _M.check_request(method, uri, body, rules, context)
    rules = type(rules) == "table" and rules or {}
    context = type(context) == "table" and context or {}

    if not context.is_mcp_path then
        return check_llm_request(rules, body)
    end

    local request = _M.parse_mcp_request(body)
    if not request then
        return true, "non-JSON body, allowing"
    end

    if request.method ~= "tools/call" then
        return true, "non-tool MCP request, allowing"
    end

    local generic_rules = effective_rules(rules, context)

    local allowed, reason = check_allowlist(generic_rules, request.tool_name)
    if not allowed then
        return false, reason
    end

    allowed, reason = check_blocklist(generic_rules, request.tool_name)
    if not allowed then
        return false, reason
    end

    allowed, reason = check_rate_limit(generic_rules, request.tool_name, context)
    if not allowed then
        return false, reason
    end

    allowed, reason = check_token_cap(generic_rules, request.arguments)
    if not allowed then
        return false, reason
    end

    allowed, reason = check_server_rules(rules, request, context)
    if not allowed then
        return false, reason
    end

    return check_time_rules(generic_rules, request.tool_name)
end

return _M