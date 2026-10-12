package.path = package.path .. ";lua/?.lua"

local cjson = require("cjson.safe")
local engine = require("rules_engine")

describe("FHIR MCP rules", function()
    local rules

    before_each(function()
        local file = assert(io.open("rules.json", "r"))
        rules = assert(cjson.decode(file:read("*a")))
        file:close()
    end)

    local function check(tool, arguments)
        return engine.check_request("POST", "/mcp/fhir", cjson.encode({
            jsonrpc = "2.0",
            id = 1,
            method = "tools/call",
            params = { name = tool, arguments = arguments or {} },
        }), rules, { is_mcp_path = true, mcp_server_name = "fhir" })
    end

    local function create(resource_type, payload)
        return check("create", { type = resource_type, payload = payload })
    end

    local function medication(name, dispense, dosage)
        return {
            resourceType = "MedicationRequest",
            status = "active",
            intent = "order",
            subject = { reference = "Patient/1000" },
            medicationCodeableConcept = { text = name },
            dispenseRequest = dispense,
            dosageInstruction = dosage,
        }
    end

    local function days(n)
        return { expectedSupplyDuration = { value = n, unit = "days", system = "http://unitsofmeasure.org", code = "d" } }
    end

    local function twice_daily(dose)
        return { {
            text = "1 tablet by mouth every 12 hours",
            timing = { ["repeat"] = { frequency = 2, period = 1, periodUnit = "d" } },
            doseAndRate = { { doseQuantity = dose or { value = 1, unit = "tablet" } } },
        } }
    end

    it("allows the four approved read tools despite the global allowlist", function()
        for _, tool in ipairs({ "search", "read", "get_capabilities", "get_user" }) do
            assert.is_true(check(tool))
        end
    end)

    it("denies update, delete and unknown tools", function()
        -- Not allowlisted and blocklisted: either layer alone denies them.
        local allowed, reason = check("update", { type = "Patient", id = "1000", payload = {} })
        assert.is_false(allowed)
        assert.truthy(reason:find("update", 1, true))

        for _, resource_type in ipairs({ "Patient", "Condition", "MedicationRequest" }) do
            allowed, reason = check("delete", { type = resource_type, id = "1000" })
            assert.is_false(allowed)
            assert.truthy(reason:find("delete", 1, true))
        end

        allowed, reason = check("execute")
        assert.is_false(allowed)
        assert.truthy(reason:find("not in allowlist", 1, true))
    end)

    it("keeps blocklist precedence over the allowlist", function()
        rules.mcp_servers.fhir.tool_allowlist.params.tools = { "create", "update", "delete" }
        assert.equals("tool is blocked: update", select(2, check("update", { type = "Condition" })))
        assert.equals("tool is blocked: delete", select(2, check("delete", { type = "Condition" })))
    end)

    it("allows creates for clinical documentation types", function()
        assert.is_true(create("Condition", {
            resourceType = "Condition",
            subject = { reference = "Patient/1000" },
            code = { text = "Seasonal allergic rhinitis" },
        }))
        assert.is_true(create("Observation", {
            resourceType = "Observation", status = "final", code = { text = "Heart rate" },
        }))
        for _, resource_type in ipairs(rules.mcp_servers.fhir.write_resource_allowlist.params.types) do
            if resource_type ~= "MedicationRequest" then
                assert.is_true(create(resource_type, { resourceType = resource_type }), resource_type)
            end
        end
    end)

    it("blocks creates for identity/administrative types", function()
        for _, resource_type in ipairs({ "Patient", "Practitioner", "Organization", "Person" }) do
            local allowed, reason = create(resource_type, { resourceType = resource_type })
            assert.is_false(allowed)
            assert.equals("resource type not allowed for write: " .. resource_type, reason)
        end
        local allowed, reason = check("create", { payload = { resourceType = "Condition" } })
        assert.is_false(allowed)
        assert.equals("resource type not allowed for write: unknown", reason)
    end)

    it("blocks payloads whose resourceType differs from the declared type", function()
        local allowed, reason = create("Condition", { resourceType = "Patient" })
        assert.is_false(allowed)
        assert.equals("resource type not allowed for write: Patient", reason)
    end)

    it("blocks all writes when the write allowlist is disabled", function()
        rules.mcp_servers.fhir.write_resource_allowlist.enabled = false
        local allowed, reason = create("Condition", { resourceType = "Condition" })
        assert.is_false(allowed)
        assert.equals("resource type not allowed for write: Condition", reason)
    end)

    it("allows a controlled substance within the 3-day cap", function()
        assert.is_true(create("MedicationRequest", medication("OxyContin 10 mg tablet", days(3))))
        assert.is_true(create("MedicationRequest", medication("OxyContin", {
            quantity = { value = 6, unit = "tablets" },
        }, twice_daily())))
    end)

    it("blocks a controlled substance over the cap via expectedSupplyDuration", function()
        local allowed, reason = create("MedicationRequest", medication("OxyContin 10 mg", days(30)))
        assert.is_false(allowed)
        assert.equals("controlled substance blocked: oxycontin exceeds max supply: 30 days > 3 days", reason)
    end)

    it("computes supply from quantity and dosage (60 pills twice daily = 30 days)", function()
        local allowed, reason = create("MedicationRequest", medication("OxyContin", {
            quantity = { value = 60, unit = "tablet" },
        }, twice_daily()))
        assert.is_false(allowed)
        assert.equals("controlled substance blocked: oxycontin exceeds max supply: 30 days > 3 days", reason)
    end)

    it("rounds partial days up before comparing to the cap", function()
        local allowed, reason = create("MedicationRequest", medication("oxycodone", {
            quantity = { value = 7, unit = "tablet" },
        }, twice_daily()))
        assert.is_false(allowed)
        assert.equals("controlled substance blocked: oxycodone exceeds max supply: 4 days > 3 days", reason)
    end)

    it("prefers expectedSupplyDuration over quantity", function()
        local dispense = days(2)
        dispense.quantity = { value = 600, unit = "tablet" }
        assert.is_true(create("MedicationRequest", medication("Fentanyl patch", dispense, twice_daily())))
    end)

    it("matches substances case-insensitively anywhere in the payload", function()
        local payload = medication("Pain relief", days(10))
        payload.note = { { text = "Patient requested DILAUDID" } }
        local allowed, reason = create("MedicationRequest", payload)
        assert.is_false(allowed)
        assert.truthy(reason:find("dilaudid exceeds max supply: 10 days > 3 days", 1, true))
    end)

    it("fails closed when days supply is not computable", function()
        local cases = {
            medication("OxyContin"),
            medication("OxyContin", { quantity = { value = 60 } }),
            medication("OxyContin", { expectedSupplyDuration = { value = 3, unit = "weeks", code = "wk" } }),
            medication("OxyContin", { expectedSupplyDuration = { value = 0, code = "d" } }),
            medication("OxyContin", { quantity = { value = 60, unit = "tablet" } },
                twice_daily({ value = 10, unit = "mg" })),
            medication("OxyContin", { quantity = { value = 60 } }, { {
                asNeeded = true, doseAndRate = { { doseQuantity = { value = 1 } } },
            } }),
            medication("OxyContin", { quantity = { value = 60 } }, { {
                timing = { ["repeat"] = { frequency = 1, frequencyMax = 4, period = 1, periodUnit = "d" } },
                doseAndRate = { { doseQuantity = { value = 1 } } },
            } }),
            medication("OxyContin", { quantity = { value = 60 } },
                { twice_daily()[1], twice_daily()[1] }),
        }
        for index, payload in ipairs(cases) do
            local allowed, reason = create("MedicationRequest", payload)
            assert.is_false(allowed, "case " .. index)
            assert.equals("controlled substance blocked: days supply not computable", reason)
        end

        local allowed, reason = create("MedicationRequest", '{"medication": "oxycontin", ')
        assert.is_false(allowed)
        assert.equals("controlled substance blocked: days supply not computable", reason)
    end)

    it("inspects payloads sent as JSON strings", function()
        local allowed, reason = create("MedicationRequest", cjson.encode(medication("OxyContin", days(30))))
        assert.is_false(allowed)
        assert.truthy(reason:find("30 days > 3 days", 1, true))
        assert.is_true(create("MedicationRequest", cjson.encode(medication("OxyContin", days(3)))))
    end)

    it("allows non-controlled prescriptions regardless of supply", function()
        assert.is_true(create("MedicationRequest", medication("Amoxicillin 500 mg capsule", days(30))))
        assert.is_true(create("MedicationRequest", medication("Amoxicillin")))
    end)

    it("applies the default cap; group_overrides is an unimplemented extension point", function()
        local params = rules.mcp_servers.fhir.controlled_substance_rules.params
        assert.equals(3, params.default_max_days_supply)
        assert.is_nil(next(params.group_overrides))

        params.group_overrides = { pain_specialists = 30 }
        assert.is_false(create("MedicationRequest", medication("OxyContin", days(30))))

        params.default_max_days_supply = 0
        assert.is_false(create("MedicationRequest", medication("OxyContin", days(1))))
        params.default_max_days_supply = nil
        assert.is_false(create("MedicationRequest", medication("OxyContin", days(1))))
    end)

    it("does not change the default server's tool rules", function()
        local allowed = engine.check_request("POST", "/mcp/dummy", cjson.encode({
            method = "tools/call",
            params = { name = "search", arguments = {} },
        }), rules, { is_mcp_path = true, mcp_server_name = "dummy" })
        assert.is_false(allowed)
    end)
end)
