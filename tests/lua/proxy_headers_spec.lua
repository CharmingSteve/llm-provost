describe("Phase 2 routing and audit configuration", function()
    local conf

    before_each(function()
        local file = assert(io.open("default.conf", "r"))
        conf = file:read("*a")
        file:close()
    end)

    it("declares the Phase 2 environment variables", function()
        assert.truthy(conf:find("env LLM_API_URL;", 1, true))
        assert.truthy(conf:find("env LLM_API_KEY;", 1, true))
        assert.truthy(conf:find("env MCP_ROUTING_TABLE_PATH;", 1, true))
    end)

    it("defines chat and MCP paths", function()
        assert.truthy(conf:find("location /v1/", 1, true))
        assert.truthy(conf:find("location ~ ^/mcp/(.+)$", 1, true))
        assert.truthy(conf:find("content_by_lua_file /etc/nginx/lua/mcp_proxy.lua;", 1, true))
    end)

    it("runs policy and body filters on both paths", function()
        local _, policy_count = conf:gsub("access_by_lua_file /etc/nginx/lua/http_policy.lua;", "")
        local _, body_filter_count = conf:gsub("body_filter_by_lua_block", "")
        assert.equals(2, policy_count)
        assert.equals(2, body_filter_count)
        assert.falsy(conf:find("log_by_lua", 1, true))
    end)

    it("records all four identity layers", function()
        assert.truthy(conf:find('"user_id":"$provost_user_id"', 1, true))
        assert.truthy(conf:find('"customer_id":"$provost_customer_id"', 1, true))
        assert.truthy(conf:find('"conversation_id":"$provost_conversation_id"', 1, true))
        assert.truthy(conf:find('"request_id":"$provost_req_id"', 1, true))
        assert.truthy(conf:find('"request_body":"$req_body"', 1, true))
        assert.truthy(conf:find('"resp_body":"$resp_body"', 1, true))
    end)

    it("does not include credentials in the log format", function()
        local format = conf:match("log_format json_full.-'}';") or ""
        assert.falsy(format:lower():find("authorization", 1, true))
        assert.falsy(format:lower():find("token", 1, true))
    end)
end)