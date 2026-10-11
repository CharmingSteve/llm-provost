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

    it("redacts configured SSNs and returns the forwarded body", function()
        local rules = {
            llm_rules = {
                enabled = true,
                params = {
                    pii_block = { "aws_access_key", "private_key_block", "github_token" },
                    pii_redact = { "us_ssn" },
                },
            },
        }
        local body = '{"messages":[{"role":"tool","content":"SSN 999-70-1676"}]}'
        local allowed, reason, redacted_body = engine.check_request(
            "POST",
            "/v1/chat/completions",
            body,
            rules,
            { is_mcp_path = false }
        )

        assert.is_true(allowed)
        assert.equals("chat path allowed", reason)
        assert.equals('{"messages":[{"role":"tool","content":"SSN ***-**-****"}]}', redacted_body)
    end)

    it("continues to block AWS access keys in chat requests", function()
        local rules = {
            llm_rules = {
                enabled = true,
                params = {
                    pii_block = { "aws_access_key" },
                    pii_redact = { "us_ssn" },
                },
            },
        }
        local allowed, reason = engine.check_request(
            "POST",
            "/v1/chat/completions",
            '{"messages":[{"role":"user","content":"AKIAIOSFODNN7EXAMPLE"}]}',
            rules,
            { is_mcp_path = false }
        )

        assert.is_false(allowed)
        assert.truthy(reason:find("aws_access_key", 1, true))
    end)

    it("returns an unchanged chat body when no configured PII is present", function()
        local body = '{"messages":[{"role":"user","content":"hello"}]}'
        local allowed, _, returned_body = engine.check_request(
            "POST",
            "/v1/chat/completions",
            body,
            { llm_rules = { enabled = true, params = { pii_redact = { "us_ssn" } } } },
            { is_mcp_path = false }
        )

        assert.is_true(allowed)
        assert.equals(body, returned_body)
    end)
end)