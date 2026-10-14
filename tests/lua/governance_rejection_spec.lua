package.path = package.path .. ";lua/?.lua"

local cjson = require("cjson.safe")

describe("shared governance rejection contract", function()
    local original_ngx, original_audit_error, original_alpaca_policy, original_trading_rules
    local emitted, said

    before_each(function()
        original_ngx = _G.ngx
        original_audit_error = package.loaded.audit_error
        original_alpaca_policy = package.loaded.alpaca_policy
        original_trading_rules = package.loaded.trading_rules
        emitted, said = nil, nil
        package.loaded.audit_error = {
            emit = function(...)
                emitted = { ... }
            end,
        }
        _G.ngx = {
            HTTP_FORBIDDEN = 403,
            HTTP_BAD_REQUEST = 400,
            status = 200,
            header = {},
            var = {},
            say = function(body) said = body end,
            exit = function(status) return status end,
        }
    end)

    after_each(function()
        _G.ngx = original_ngx
        package.loaded.audit_error = original_audit_error
        package.loaded.alpaca_policy = original_alpaca_policy
        package.loaded.trading_rules = original_trading_rules
    end)

    it("uses the same branded response and audit structure across MCP servers", function()
        local reject = require("governance_rejection").reject
        for _, server in ipairs({
            { code = "PROVOST_INTERVENTION", tag = "provost_mcp_to_api_error" },
            { code = "PROVOST_INTERVENTION", tag = "provost_fhir_error" },
        }) do
            local detail = "blocked write"
            assert.equals(403, reject(ngx, 403, server.code, detail, server.tag))
            local body = assert(cjson.decode(said))
            assert.same({
                error = server.code,
                detail = "PROVOST_INTERVENTION: " .. detail,
            }, body)
            assert.equals(server.tag, emitted[1])
            assert.equals(403, emitted[2])
            assert.equals(server.code, emitted[3])
            assert.equals(body.detail, emitted[4])
            assert.same(body, cjson.decode(emitted[5].resp_body))
            assert.equals(said, ngx.var.resp_body)
        end
    end)

    it("does not brand non-governance request errors", function()
        local reject = require("governance_rejection").reject
        assert.equals(400, reject(
            ngx,
            400,
            "FHIR_BAD_REQUEST",
            "bad URI",
            "provost_fhir_error"
        ))
        local body = assert(cjson.decode(said))
        assert.same({ error = "FHIR_BAD_REQUEST", detail = "bad URI" }, body)
        assert.equals("bad URI", emitted[4])
    end)

    it("routes Alpaca governance rejections through the shared contract", function()
        _G.ngx.now = function() return 1 end
        _G.ngx.HTTP_GET = "GET"
        _G.ngx.var.uri = "/trading/orders"
        _G.ngx.req = {
            get_method = function() return "POST" end,
            get_body_data = function() return "{}" end,
            set_header = function() end,
        }
        _G.ngx.shared = { rules = { get = function() return "{}" end } }
        package.loaded.trading_rules = {
            check_http_request = function()
                return true, "blocked trade"
            end,
        }
        package.loaded.alpaca_policy = nil

        local policy = require("alpaca_policy")
        assert.equals(403, policy.enforce("trading"))
        local body = assert(cjson.decode(said))
        assert.same({
            error = "PROVOST_INTERVENTION",
            detail = "PROVOST_INTERVENTION: blocked trade",
        }, body)
        assert.equals("provost_mcp_to_api_error", emitted[1])
        assert.equals("PROVOST_INTERVENTION", emitted[3])
        assert.equals(body.detail, emitted[4])
        assert.same(body, cjson.decode(emitted[5].resp_body))
    end)
end)
