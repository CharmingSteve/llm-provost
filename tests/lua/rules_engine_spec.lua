package.path = package.path .. ";lua/?.lua"

local engine = require("rules_engine")

local function body(tool_name, arguments)
    return string.format(
        '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"%s","arguments":%s}}',
        tool_name,
        arguments or "{}"
    )
end

local function context()
    return {
        user_id = "user-1",
        customer_id = "customer-1",
        conversation_id = "conversation-1",
        is_mcp_path = true,
    }
end

describe("rules_engine MCP governance", function()
    it("parses JSON-RPC tool calls", function()
        local request = engine.parse_mcp_request(body("get_records", '{"customer_id":"c-1"}'))
        assert.equals("tools/call", request.method)
        assert.equals("get_records", request.tool_name)
        assert.equals("c-1", request.arguments.customer_id)
        assert.equals(1, request.id)
    end)

    it("returns nil for invalid JSON", function()
        assert.is_nil(engine.parse_mcp_request("not-json"))
    end)

    it("blocks tools outside the enabled allowlist", function()
        local rules = {
            tool_allowlist = {
                enabled = true,
                params = { tools = { "get_records" } },
            },
        }
        local allowed, reason = engine.check_request("POST", "/mcp/dummy", body("delete_record"), rules, context())
        assert.is_false(allowed)
        assert.truthy(reason:find("not in allowlist", 1, true))
    end)

    it("blocks tools in the enabled blocklist", function()
        local rules = {
            tool_blocklist = {
                enabled = true,
                params = { tools = { "delete_record" } },
            },
        }
        local allowed, reason = engine.check_request("POST", "/mcp/dummy", body("delete_record"), rules, context())
        assert.is_false(allowed)
        assert.truthy(reason:find("tool is blocked", 1, true))
    end)

    it("blocks max_tokens above the configured cap", function()
        local rules = {
            token_caps = {
                enabled = true,
                params = { max_tokens = 100 },
            },
        }
        local allowed, reason = engine.check_request(
            "POST",
            "/mcp/dummy",
            body("summarize_report", '{"max_tokens":101}'),
            rules,
            context()
        )
        assert.is_false(allowed)
        assert.truthy(reason:find("token cap exceeded", 1, true))
    end)

    it("allows non-tool MCP requests and non-JSON handshakes", function()
        local allowed_non_tool = engine.check_request(
            "POST",
            "/mcp/dummy",
            '{"jsonrpc":"2.0","method":"initialize"}',
            {},
            context()
        )
        local allowed_handshake = engine.check_request("GET", "/mcp/dummy", "", {}, context())
        assert.is_true(allowed_non_tool)
        assert.is_true(allowed_handshake)
    end)

    it("allows chat requests without applying MCP rules", function()
        local allowed, reason = engine.check_request(
            "POST",
            "/v1/chat/completions",
            "{}",
            { tool_allowlist = { enabled = true, params = { tools = {} } } },
            { is_mcp_path = false }
        )
        assert.is_true(allowed)
        assert.equals("chat path allowed", reason)
    end)
end)