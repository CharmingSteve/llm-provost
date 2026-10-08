package.path = package.path .. ";lua/?.lua"

describe("FHIR outbound read-only boundary", function()
    local original_ngx, original_identity
    local base, output, resolved, environment

    before_each(function()
        original_ngx = _G.ngx
        original_identity = package.loaded.outbound_identity
        base = "https://example.test/baseR4/"
        output, resolved = nil, false
        environment = setmetatable({
            os = { getenv = function() return base end },
        }, { __index = _G })
        package.loaded.outbound_identity = {
            resolve = function() resolved = true end,
        }
        _G.ngx = {
            req = { get_method = function() return "GET" end },
            var = { request_uri = "/fhir/Patient?_count=1&name=A%20B" },
            header = {},
            HTTP_FORBIDDEN = 403,
            HTTP_INTERNAL_SERVER_ERROR = 500,
            say = function(value) output = value end,
            exit = function(status) return status end,
        }
    end)

    after_each(function()
        _G.ngx = original_ngx
        package.loaded.outbound_identity = original_identity
    end)

    local function run()
        local chunk = assert(loadfile("lua/fhir_policy.lua"))
        setfenv(chunk, environment)
        return chunk()
    end

    it("restores audit identity and preserves the base path and escaped query", function()
        run()
        assert.is_true(resolved)
        assert.equals("https://example.test/baseR4/Patient?_count=1&name=A%20B",
            ngx.var.fhir_target_url)
    end)

    it("defaults to the external HAPI server and supports the route root", function()
        base = nil
        ngx.var.request_uri = "/fhir?_format=json"
        ngx.req.get_method = function() return "HEAD" end
        run()
        assert.equals("http://hapi.fhir.org/baseR4/?_format=json", ngx.var.fhir_target_url)
    end)

    it("rejects every write verb before configuring an upstream", function()
        for _, method in ipairs({ "POST", "PUT", "PATCH", "DELETE" }) do
            ngx.req.get_method = function() return method end
            assert.equals(403, run())
            assert.is_true(resolved)
            assert.is_nil(ngx.var.fhir_target_url)
            assert.truthy(output:find("read-only", 1, true))
        end
    end)

    it("fails closed for invalid backend configuration", function()
        for _, invalid in ipairs({
            "file:///etc/passwd", "https://user@example.test/fhir",
            "https://example.test/fhir?query=1", "https://example.test/fhir#fragment",
            "",
        }) do
            base = invalid
            assert.equals(500, run())
            assert.is_nil(ngx.var.fhir_target_url)
        end
    end)
end)
