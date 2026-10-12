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

-- Built-in PII patterns for LLM chat prompts. Entries can be enabled via
-- llm_rules.params.pii_block or pii_redact; custom Lua patterns can be added
-- via llm_rules.params.pii_patterns.
local BUILTIN_PII_PATTERNS = {
    us_ssn = "%f[%d]%d%d%d%-%d%d%-%d%d%d%d%f[%D]",
    aws_access_key = "AKIA[%u%d][%u%d][%u%d][%u%d][%u%d][%u%d][%u%d][%u%d]"
        .. "[%u%d][%u%d][%u%d][%u%d][%u%d][%u%d][%u%d][%u%d]",
    private_key_block = "%-%-%-%-%-BEGIN[%u%s]-PRIVATE KEY%-%-%-%-%-",
    github_token = "gh[pousr]_%w%w%w%w%w%w%w%w%w%w%w%w%w%w%w%w",
}

local MASKS = {
    us_ssn = "***-**-****",
}

local function check_llm_pii(params, body)
    if type(body) ~= "string" or body == "" then
        return true, nil, body
    end

    if type(params.pii_block) == "table" then
        for _, name in ipairs(params.pii_block) do
            local pattern = BUILTIN_PII_PATTERNS[name]
            if pattern and body:find(pattern) then
                return false, "PII filter blocked prompt: " .. name .. " detected", body
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
                    return false, "PII filter blocked prompt: " .. tostring(name) .. " detected", body
                end
            end
        end
    end

    local redacted_body = body
    if type(params.pii_redact) == "table" then
        for _, name in ipairs(params.pii_redact) do
            local pattern = BUILTIN_PII_PATTERNS[name]
            if pattern then
                redacted_body = redacted_body:gsub(pattern, MASKS[name] or "****")
            end
        end
    end

    return true, nil, redacted_body
end

local function check_llm_request(rules, body)
    local params = enabled_params(rules.llm_rules)
    if not params then
        return true, "chat path allowed", body
    end

    local allowed, reason, redacted_body = check_llm_pii(params, body)
    if not allowed then
        return false, reason, redacted_body
    end

    local maximum = tonumber(params.max_tokens)
    if maximum then
        local parsed = cjson.decode(redacted_body or "")
        local requested = type(parsed) == "table" and tonumber(parsed.max_tokens)
        if requested and requested > maximum then
            return false, "token cap exceeded: requested " .. requested .. ", max " .. maximum, redacted_body
        end
    end

    return true, "chat path allowed", redacted_body
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

-- ---------------------------------------------------------------------------
-- Selective write governance (rules.mcp_servers[<server>].write_resource_allowlist
-- and .controlled_substance_rules). Deterministic string/number logic only.
-- ---------------------------------------------------------------------------

local function positive_number(value)
    local n = tonumber(value)
    if not n or n ~= n or n == math.huge or n <= 0 then
        return nil
    end
    return n
end

local function single_entry(list)
    if type(list) ~= "table" or #list ~= 1 or type(list[1]) ~= "table" then
        return nil
    end
    return list[1]
end

-- "Tablets", "{tablet}" and "tablet" compare equal; anything else must match.
local function normalize_unit(quantity)
    local unit = quantity.code or quantity.unit
    if type(unit) ~= "string" then
        return nil
    end
    unit = unit:lower():gsub("[{}%s]", "")
    if unit:sub(-1) == "s" and #unit > 1 then
        unit = unit:sub(1, -2)
    end
    return unit ~= "" and unit or nil
end

local PERIOD_UNITS_PER_DAY = { h = 24, d = 1, wk = 1 / 7 }

-- dosageInstruction -> per-dose quantity table and doses per day, or nil when
-- absent or ambiguous (several instructions, dose/frequency ranges, PRN-only).
local function parse_dosage(dosage_instructions)
    local instruction = single_entry(dosage_instructions)
    if not instruction then
        return nil
    end

    local dose_and_rate = single_entry(instruction.doseAndRate)
    local dose = dose_and_rate and dose_and_rate.doseQuantity
    if type(dose) ~= "table" or not positive_number(dose.value) then
        return nil
    end

    local timing = type(instruction.timing) == "table" and instruction.timing["repeat"]
    if type(timing) ~= "table"
       or timing.frequencyMax ~= nil
       or timing.periodMax ~= nil then
        return nil
    end
    local frequency = positive_number(timing.frequency)
    local period = positive_number(timing.period)
    local per_day = PERIOD_UNITS_PER_DAY[timing.periodUnit]
    if not frequency or not period or not per_day then
        return nil
    end

    return dose, frequency * per_day / period
end

-- Days supply of a MedicationRequest, or nil when not computable. Priority:
--   a. dispenseRequest.expectedSupplyDuration in day units
--   b. dispenseRequest.quantity / (dose quantity * doses per day)
local function compute_days_supply(payload)
    local dispense = type(payload) == "table" and payload.dispenseRequest
    if type(dispense) ~= "table" then
        return nil
    end

    local duration = dispense.expectedSupplyDuration
    if type(duration) == "table" then
        local unit = type(duration.unit) == "string" and duration.unit:lower() or ""
        local value = positive_number(duration.value)
        if value and (duration.code == "d" or unit:find("day", 1, true)) then
            return value
        end
    end

    local quantity = dispense.quantity
    local total = type(quantity) == "table" and positive_number(quantity.value)
    if not total then
        return nil
    end
    local dose, doses_per_day = parse_dosage(payload.dosageInstruction)
    if not dose then
        return nil
    end
    local total_unit, dose_unit = normalize_unit(quantity), normalize_unit(dose)
    if total_unit and dose_unit and total_unit ~= dose_unit then
        return nil
    end

    return total / (tonumber(dose.value) * doses_per_day)
end

-- Applicable controlled-substance cap (days) for the caller.
--
-- Extension point (NOT implemented yet): resolve the caller's OIDC groups from
-- the identity headers already transiting the proxy (via context) and return
-- the matching params.group_overrides[<group>] value (0 = blocked). Until
-- then, everyone gets default_max_days_supply. A missing or invalid default
-- fails closed to 0 (controlled substances blocked).
local function get_max_days_supply(params, _context)
    local cap = tonumber(params.default_max_days_supply)
    if not cap or cap ~= cap or cap < 0 then
        return 0
    end
    return cap
end

local function format_days(days)
    if days == math.floor(days) then
        return string.format("%d", days)
    end
    return string.format("%.1f", days)
end

local function check_controlled_substance(server_rules, payload, serialized, context)
    local params = enabled_params(server_rules.controlled_substance_rules)
    if not params or type(params.substances) ~= "table" then
        return true
    end
    if type(serialized) ~= "string" then
        return false, "controlled substance blocked: payload not inspectable"
    end
    serialized = serialized:lower()

    local substance
    for _, candidate in ipairs(params.substances) do
        if type(candidate) == "string" and candidate ~= ""
           and serialized:find(candidate:lower(), 1, true) then
            substance = candidate:lower()
            break
        end
    end
    if not substance then
        return true
    end

    local days = compute_days_supply(payload)
    if not days then
        return false, "controlled substance blocked: days supply not computable"
    end
    -- Round up partial days (absorbing float noise) so caps compare in whole days.
    days = math.ceil(days - 1e-9)

    local cap = get_max_days_supply(params, context)
    if days > cap then
        return false, "controlled substance blocked: " .. substance
            .. " exceeds max supply: " .. format_days(days) .. " days > "
            .. format_days(cap) .. " days"
    end

    return true
end

-- Governs the `create` tool for servers that declare write_resource_allowlist.
-- A disabled or missing type list allows no writes (fail-closed), matching the
-- REST hop in fhir_policy.lua.
local function check_write_rules(rules, request, context)
    local server_rules = get_server_rules(rules, context)
    if not server_rules
       or server_rules.write_resource_allowlist == nil
       or request.tool_name ~= "create" then
        return true
    end

    local arguments = type(request.arguments) == "table" and request.arguments or {}
    local resource_type = type(arguments.type) == "string" and arguments.type or "unknown"
    local params = enabled_params(server_rules.write_resource_allowlist)
    if not params or not contains(params.types, resource_type) then
        return false, "resource type not allowed for write: " .. resource_type
    end

    -- Payload may arrive as an object or a JSON string; inspect both forms.
    local payload, serialized = arguments.payload, nil
    if type(payload) == "string" then
        payload, serialized = cjson.decode(payload), payload
    else
        serialized = cjson.encode(payload)
    end

    local declared = type(payload) == "table" and payload.resourceType
    if type(declared) == "string" and declared ~= resource_type then
        return false, "resource type not allowed for write: " .. declared
    end

    if resource_type == "MedicationRequest" then
        return check_controlled_substance(server_rules, payload, serialized, context)
    end

    return true
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

    allowed, reason = check_write_rules(rules, request, context)
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