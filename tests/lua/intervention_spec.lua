package.path = package.path .. ";lua/?.lua"

local intervention = require("intervention")

describe("PROVOST_INTERVENTION brand", function()
    it("prefixes bare reasons", function()
        assert.equals("PROVOST_INTERVENTION: tool not in allowlist: create",
            intervention.brand("tool not in allowlist: create"))
    end)

    it("never double-prefixes", function()
        local once = intervention.brand("Replace Notional Exceeds Limit")
        assert.equals(once, intervention.brand(once))
        local _, count = once:gsub("PROVOST_INTERVENTION", "")
        assert.equals(1, count)
    end)
end)

describe("http_policy governance rejection", function()
    local original_ngx, emitted, said

    local function run(reason_from_engine, is_mcp)
        emitted, said = nil, nil
        package.loaded.audit_error = { emit = function(...) emitted = { ... } end }
        package.loaded.audit_body = { compact_request = function(b) return b end }
        package.loaded.routes = { get = function() return "dest" end }
        package.loaded.rules_engine = {
            check_request = function() return false, reason_from_engine end,
        }
        local headers = { ["X-Provost-Token"] = "tok" }
        _G.ngx = {
            HTTP_FORBIDDEN = 403, HTTP_UNAUTHORIZED = 401,
            HTTP_INTERNAL_SERVER_ERROR = 500, HTTP_NOT_FOUND = 404,
            shared = {},
            ctx = {},
            header = {},
            var = { uri = is_mcp and "/mcp/alpaca/" or "/llm/x/v1/chat", request_id = "r" },
            req = {
                get_headers = function() return headers end,
                get_method = function() return "POST" end,
                read_body = function() end,
                get_body_data = function() return "{}" end,
            },
            decode_base64 = function() return nil end,
            say = function(v) said = v end,
            exit = function(s) return s end,
        }
        local env = setmetatable({
            os = { getenv = function(k)
                if k == "PROVOST_TOKEN" then return headers["X-Provost-Token"] == "tok" and "tok" or "x" end
            end },
        }, { __index = _G })
        local chunk
        if setfenv then
            chunk = assert(loadfile("lua/http_policy.lua"))
            setfenv(chunk, env)
        else
            chunk = assert(loadfile("lua/http_policy.lua", "t", env))
        end
        return chunk()
    end

    before_each(function() original_ngx = _G.ngx end)
    after_each(function()
        _G.ngx = original_ngx
        for _, m in ipairs({ "audit_error", "audit_body", "routes", "rules_engine" }) do
            package.loaded[m] = nil
        end
    end)

    it("prefixes the reason once in the response and the audit record", function()
        run("tool not in allowlist: create", true)
        local expected = "PROVOST_INTERVENTION: tool not in allowlist: create"
        assert.truthy(said:find('"detail":"' .. expected .. '"', 1, true))
        assert.truthy(said:find('"error":"GOVERNANCE_VIOLATION"', 1, true))
        assert.equals(expected, emitted[4])
    end)

    it("does not double-prefix an already branded reason", function()
        run("PROVOST_INTERVENTION: Replace Notional Exceeds Limit", true)
        local _, count = said:gsub("PROVOST_INTERVENTION", "")
        assert.equals(1, count)
    end)
end)
