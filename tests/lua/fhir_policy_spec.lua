package.path = package.path .. ";lua/?.lua"

local rules_json = (function()
    local file = assert(io.open("rules.json", "r"))
    local content = file:read("*a")
    file:close()
    return content
end)()

describe("FHIR outbound write boundary", function()
    local original_ngx, original_identity, original_audit_error
    local base, output, resolved, environment, shared_rules, emitted

    before_each(function()
        original_ngx = _G.ngx
        original_identity = package.loaded.outbound_identity
        original_audit_error = package.loaded.audit_error
        base = "https://example.test/baseR4/"
        output, resolved, emitted = nil, false, nil
        shared_rules = rules_json
        environment = setmetatable({
            os = { getenv = function() return base end },
        }, { __index = _G })
        package.loaded.outbound_identity = {
            resolve = function(allow_last_known)
                assert.is_false(allow_last_known)
                resolved = true
            end,
        }
        package.loaded.audit_error = {
            emit = function(...)
                emitted = { ... }
            end,
        }
        _G.ngx = {
            req = { get_method = function() return "GET" end },
            var = { request_uri = "/fhir/Patient?_count=1&name=A%20B" },
            header = {},
            shared = { rules = { get = function() return shared_rules end } },
            HTTP_FORBIDDEN = 403,
            HTTP_BAD_REQUEST = 400,
            HTTP_INTERNAL_SERVER_ERROR = 500,
            ERR = "error",
            ctx = {},
            say = function(value) output = value end,
            exit = function(status) return status end,
            log = function() end,
            utctime = function() return "2026-10-13 00:00:00" end,
            decode_base64 = function() return nil end,
        }
    end)

    after_each(function()
        _G.ngx = original_ngx
        package.loaded.outbound_identity = original_identity
        package.loaded.audit_error = original_audit_error
    end)

    local function run()
        -- Lua 5.2+ binds the environment via loadfile; 5.1 (CI) via setfenv.
        local chunk = assert(loadfile("lua/fhir_policy.lua", "t", environment))
        if setfenv then
            setfenv(chunk, environment)
        end
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

    local function assert_rejected(method, request_uri)
        ngx.req.get_method = function() return method end
        ngx.var.request_uri = request_uri
        ngx.var.fhir_target_url = nil
        assert.equals(403, run(), method .. " " .. request_uri)
        assert.is_true(resolved)
        assert.is_nil(ngx.var.fhir_target_url)
        local body = assert(require("cjson.safe").decode(output))
        assert.equals("PROVOST_INTERVENTION", body.error)
        assert.truthy(body.detail:find("read-only", 1, true))
        assert.equals("provost_fhir_error", emitted[1])
        assert.equals(403, emitted[2])
        assert.equals("PROVOST_INTERVENTION", emitted[3])
        assert.equals(body.detail, emitted[4])
        assert.equals(body.detail, require("cjson.safe").decode(emitted[5].resp_body).detail)
    end

    it("allows POST creates for clinical documentation types", function()
        ngx.req.get_method = function() return "POST" end
        for _, request_uri in ipairs({
            "/fhir/Condition", "/fhir/Observation", "/fhir/MedicationRequest/",
            "/fhir/AllergyIntolerance?_format=json",
        }) do
            ngx.var.request_uri = request_uri
            ngx.var.fhir_target_url = nil
            run()
            assert.equals("https://example.test/baseR4" .. request_uri:sub(6),
                ngx.var.fhir_target_url)
        end
    end)

    it("rejects POST for identity/administrative types", function()
        for _, resource in ipairs({ "Patient", "Practitioner", "Organization", "Person" }) do
            assert_rejected("POST", "/fhir/" .. resource)
        end
    end)

    it("rejects transactions, instance paths and operations even for allowed types", function()
        for _, request_uri in ipairs({
            "/fhir", "/fhir/", "/fhir?_format=json", "/fhir/Condition/123",
            "/fhir/Condition/_search", "/fhir/Condition/$validate",
            "/fhir//Condition", "/fhir/Condition/../Patient", "/fhir/%43ondition",
            "/fhir/condition",
        }) do
            assert_rejected("POST", request_uri)
        end
    end)

    it("rejects PUT, PATCH and DELETE for every type", function()
        for _, method in ipairs({ "PUT", "PATCH", "DELETE", "OPTIONS" }) do
            for _, request_uri in ipairs({ "/fhir/Patient", "/fhir/Condition", "/fhir/Condition/1" }) do
                assert_rejected(method, request_uri)
            end
        end
    end)

    it("fails closed to read-only when rules are missing, invalid or disabled", function()
        local disabled = rules_json:gsub('("write_resource_allowlist": {%s*"enabled": )true', "%1false")
        assert.are_not.equal(rules_json, disabled)
        for _, value in ipairs({ false, "{not json", "{}", disabled }) do
            shared_rules = value or nil
            assert_rejected("POST", "/fhir/Condition")
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

    it("rejects raw URIs without an exact FHIR prefix boundary", function()
        for _, request_uri in ipairs({
            "/fhir.attacker.example/../fhir/Patient",
            "/%66hir/Patient",
        }) do
            ngx.var.request_uri = request_uri
            assert.equals(400, run())
            assert.is_nil(ngx.var.fhir_target_url)
            local body = assert(require("cjson.safe").decode(output))
            assert.equals("FHIR_BAD_REQUEST", body.error)
            assert.truthy(body.detail:find("Invalid FHIR request URI", 1, true))
            assert.equals("provost_fhir_error", emitted[1])
            assert.equals("FHIR_BAD_REQUEST", emitted[3])
        end
    end)
end)
