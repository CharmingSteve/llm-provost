package.path = package.path .. ";lua/?.lua"

local cjson = require("cjson.safe")
local engine = require("rules_engine")

describe("FHIR read-only MCP rules", function()
    local rules

    before_each(function()
        local file = assert(io.open("rules.json", "r"))
        rules = assert(cjson.decode(file:read("*a")))
        file:close()
    end)

    local function check(tool)
        return engine.check_request("POST", "/mcp/fhir", cjson.encode({
            jsonrpc = "2.0",
            id = 1,
            method = "tools/call",
            params = { name = tool, arguments = {} },
        }), rules, { is_mcp_path = true, mcp_server_name = "fhir" })
    end

    it("allows the four approved read tools despite the global allowlist", function()
        for _, tool in ipairs({ "search", "read", "get_capabilities", "get_user" }) do
            assert.is_true(check(tool))
        end
    end)

    it("denies writes and unknown tools", function()
        for _, tool in ipairs({ "create", "update", "delete", "execute" }) do
            local allowed, reason = check(tool)
            assert.is_false(allowed)
            assert.truthy(reason:find("not in allowlist", 1, true))
        end
    end)

    it("does not change the default server's tool rules", function()
        local allowed = engine.check_request("POST", "/mcp/dummy", cjson.encode({
            method = "tools/call",
            params = { name = "search", arguments = {} },
        }), rules, { is_mcp_path = true, mcp_server_name = "dummy" })
        assert.is_false(allowed)
    end)
end)
