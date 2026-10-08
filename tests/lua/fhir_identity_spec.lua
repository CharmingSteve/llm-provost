package.path = package.path .. ";lua/?.lua"

local cjson = require("cjson.safe")
local identity = require("outbound_identity")

describe("FHIR outbound audit identity isolation", function()
    local original_ngx

    before_each(function()
        original_ngx = _G.ngx
        local values = {
            ["last:request_id"] = "another-request",
            ["last:user_id"] = "another-user",
            ["last:customer_id"] = "another-customer",
            ["last:conversation_id"] = "another-conversation",
            ["req:forwarded-id"] = cjson.encode({
                user_id = "caller", customer_id = "tenant", conversation_id = "conversation",
            }),
        }
        _G.ngx = {
            var = { request_id = "outbound-request" },
            req = {
                get_headers = function() return {} end,
                get_body_data = function() return nil end,
                set_header = function() end,
            },
            shared = { provost_ctx = { get = function(_, key) return values[key] end } },
        }
    end)

    after_each(function()
        _G.ngx = original_ngx
    end)

    it("does not reuse another caller's identity when WSO2 drops headers", function()
        identity.resolve(false)
        assert.equals("outbound-request", ngx.var.provost_req_id)
        assert.equals("unknown", ngx.var.provost_user_id)
        assert.equals("unknown", ngx.var.provost_customer_id)
        assert.equals("none", ngx.var.provost_conversation_id)
    end)

    it("still restores identity when an explicit correlation header is forwarded", function()
        ngx.var.http_x_provost_request_id = "forwarded-id"
        identity.resolve(false)
        assert.equals("forwarded-id", ngx.var.provost_req_id)
        assert.equals("caller", ngx.var.provost_user_id)
        assert.equals("tenant", ngx.var.provost_customer_id)
        assert.equals("conversation", ngx.var.provost_conversation_id)
    end)

    it("preserves the existing Alpaca fallback behavior by default", function()
        identity.resolve()
        assert.equals("another-request", ngx.var.provost_req_id)
        assert.equals("another-user", ngx.var.provost_user_id)
    end)
end)
