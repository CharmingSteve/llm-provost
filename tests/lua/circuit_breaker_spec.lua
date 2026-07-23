describe("Phase 2 access policy", function()
    local policy

    before_each(function()
        local file = assert(io.open("lua/http_policy.lua", "r"))
        policy = file:read("*a")
        file:close()
    end)

    it("uses Cognito headers for MCP and JWT claims for chat", function()
        assert.truthy(policy:find("X-Cognito-User", 1, true))
        assert.truthy(policy:find("Authorization", 1, true))
        assert.truthy(policy:find("claims.sub or claims.email", 1, true))
    end)

    it("extracts customer and conversation identifiers with defaults", function()
        assert.truthy(policy:find("X-Conversation-Id", 1, true))
        assert.truthy(policy:find('customer_id = "craig"', 1, true))
        assert.truthy(policy:find('conversation_id = "none"', 1, true))
    end)

    it("passes the MCP context to the rules engine", function()
        assert.truthy(policy:find("rules_engine.check_request", 1, true))
        assert.truthy(policy:find("is_mcp_path = is_mcp_path", 1, true))
    end)

    it("contains no static token validation", function()
        assert.falsy(policy:find("PROVOST_TOKEN", 1, true))
    end)
end)