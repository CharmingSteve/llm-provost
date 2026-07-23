package.path = package.path .. ";lua/?.lua"

local engine = require("rules_engine")

local context = { user_id = "user-1", is_mcp_path = true }
local rules = {
    tool_allowlist = {
        enabled = true,
        params = { tools = { "get_records" } },
    },
    tool_blocklist = {
        enabled = true,
        params = { tools = { "delete_record" } },
    },
}

local function check(raw)
    return engine.check_request("POST", "/mcp/dummy", raw, rules, context)
end

describe("rules_engine adversarial inputs", function()
    it("does not normalize padded tool names into allowlisted names", function()
        local allowed = check('{"method":"tools/call","params":{"name":" get_records ","arguments":{}}}')
        assert.is_false(allowed)
    end)

    it("does not allow an array-valued tool name", function()
        local allowed = check('{"method":"tools/call","params":{"name":["get_records"],"arguments":{}}}')
        assert.is_false(allowed)
    end)

    it("applies blocklist after allowlist when lists overlap", function()
        rules.tool_allowlist.params.tools = { "delete_record" }
        local allowed, reason = check('{"method":"tools/call","params":{"name":"delete_record","arguments":{}}}')
        assert.is_false(allowed)
        assert.truthy(reason:find("blocked", 1, true))
    end)
end)