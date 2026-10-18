# LLM Provost — Dynamic Governance Rules Engine

This document describes the hot-reloadable, JSON-driven governance policy system used by LLM Provost.

---

## Overview

The enforcement path is split across:

| Component | Path | Purpose |
|---|---|---|
| Rules config | `rules.json` | Declarative governance policy |
| Rule engine | `lua/rules_engine.lua` | Request evaluation logic |
| Rule loader | `lua/rule_loader.lua` | Background reload of `rules.json` |
| Shared dict | `lua_shared_dict rules 1m` | Cross-worker in-memory policy cache |

The reload mechanism is unchanged from the prior implementation: `rules.json` is polled every 10 seconds using file `mtime`, validated before load, and retained in shared memory so request handling avoids per-request disk I/O.

---

## Rules Schema

Phase 1 replaces the trading-focused schema with governance-focused top-level objects.

### `tool_allowlist`

If present, only the listed tools are permitted.

```json
"tool_allowlist": {
  "enabled": true,
  "description": "Allow only approved read-oriented MCP tools.",
  "params": {
    "tools": [
      "get_records",
      "list_items",
      "summarize_report",
      "export_summary"
    ]
  }
}
```

### `tool_blocklist`

Blocked tools are denied even if they also appear in an allowlist.

```json
"tool_blocklist": {
  "enabled": true,
  "description": "Block destructive or bulk-export operations.",
  "params": {
    "tools": [
      "delete_record",
      "export_full_database"
    ]
  }
}
```

### `rate_limits`

Per-tool rate limits let operators throttle expensive or sensitive tools.

```json
"rate_limits": {
  "enabled": true,
  "description": "Apply per-tool rate windows.",
  "params": {
    "rules": {
      "get_records": {
        "max_calls": 10,
        "window_seconds": 60
      },
      "summarize_report": {
        "max_calls": 20,
        "window_seconds": 300
      }
    }
  }
}
```

### `token_caps`

Token budgets can cap runaway prompt or completion sizes.

```json
"token_caps": {
  "enabled": true,
  "description": "Limit token-heavy requests.",
  "params": {
    "max_tokens": 4096,
    "max_prompt_tokens": 8192
  }
}
```

### `time_based_rules`

Restrict tool use to approved windows.

```json
"time_based_rules": {
  "enabled": true,
  "description": "Restrict selected tools to staffed business hours.",
  "params": {
    "rules": [
      {
        "tool": "export_summary",
        "allowed_hours": "09:00-17:00",
        "timezone": "America/New_York"
      }
    ]
  }
}
```

### `logging_rules`

These settings define audit expectations for every request.

```json
"logging_rules": {
  "enabled": true,
  "description": "Require identity-rich audit logging.",
  "params": {
    "always_log_user_id": true,
    "always_log_customer_id": true,
    "always_log_tool_name": true,
    "redact_prompt_content": false
  }
}
```

### LLM prompt PII handling

`llm_rules.params.pii_block` hard-blocks matching prompts with HTTP 403. Names
in the optional `llm_rules.params.pii_redact` list are masked before an LLM
request is forwarded; the pre-redaction body is preserved in the
`req_body_original` access-log field when a replacement occurs.

---

## FHIR Selective Write Governance

FHIR writes are enforced at two independent layers:

| Layer | File | What it checks |
|---|---|---|
| MCP tool call | `lua/rules_engine.lua` | Tool allow/blocklist, resource type, controlled-substance supply cap |
| REST hop (MCP server → FHIR) | `lua/fhir_policy.lua` | HTTP method and resource type only |

### `mcp_servers.fhir.write_resource_allowlist`

The `create` tool is allowed only for the clinical documentation working set a
physician needs: `Condition`, `MedicationRequest`, `Observation`, `Encounter`,
`AllergyIntolerance`, `Procedure`, `Immunization`, `DiagnosticReport`,
`CarePlan`, `ServiceRequest`, `DocumentReference`, `Communication`,
`ClinicalImpression`.

- The type comes from the tool's `arguments.type`. Types not on the list are blocked
  with `resource type not allowed for write: <Type>`. A payload whose
  `resourceType` differs from `arguments.type` is blocked the same way.
- Identity and administrative records (`Patient`, `Practitioner`, `Organization`, …)
  are excluded on purpose.
- Deletions and updates are excluded on purpose. `update` and `delete` stay in the
  FHIR `tool_blocklist`, and the blocklist still overrides the allowlist. Under
  HIPAA record-retention rules, a correction is a new amendment, not a deletion of
  the original record.
- On the REST hop, `GET`/`HEAD` are always allowed. `POST` is allowed only for a
  plain create, `POST /fhir/<Type>`, where `<Type>` is on the list. Transactions
  and batches (`POST /fhir`), instance paths, operations, `PUT`, `PATCH` and
  `DELETE` are rejected with the read-only message.
- Fail-closed: if the rule is disabled or missing, or the shared rules can't be
  parsed, no writes are allowed at either layer (read-only behavior).

### `mcp_servers.fhir.controlled_substance_rules`

These checks apply only to `create` with type `MedicationRequest`, and only in
the rules engine, which has the parsed tool arguments. The REST hop checks
resource type only.

1. **Match:** each name in `params.substances` is matched as a case-insensitive
   substring against the serialized `arguments.payload`. A payload sent as an
   object or as a JSON string is handled the same way. If nothing matches, the
   prescription follows the normal write path, whatever its supply.
2. **Days supply** is computed deterministically, in this priority order:
   1. `dispenseRequest.expectedSupplyDuration`, when expressed in days
      (`code: "d"` or a `unit` containing "day").
   2. `dispenseRequest.quantity.value ÷ (dose quantity × doses per day)`. This is
      used only when the input is unambiguous:
      - exactly one `dosageInstruction` with exactly one `doseAndRate.doseQuantity`
      - `timing.repeat` has `frequency`, `period` and `periodUnit` (`h`, `d` or
        `wk`), with no `frequencyMax`/`periodMax`
      - quantity and dose units match when both are given (case and plural are
        ignored)
   3. Otherwise the request is **blocked**:
      `controlled substance blocked: days supply not computable` (fail-closed).

   Partial days are rounded up. For example, 60 tablets at 1 tablet twice daily is 30 days.
3. **Cap:** if the computed days exceed `get_max_days_supply()`, the request is
   blocked:
   `controlled substance blocked: <substance> exceeds max supply: <N> days > <cap> days`.

`get_max_days_supply()` currently returns `params.default_max_days_supply`
(3) for every caller. A missing or invalid default fails closed to 0.

### Future: OIDC group caps (not implemented yet)

`params.group_overrides` is a documented extension point and must stay empty for
now. When role tiers are added:

- Keys will be OIDC group names (e.g. `nurses`, `er_doctors`, `gps`,
  `pain_specialists`).
- Values will be the maximum days supply for that group. `0` means blocked.
- `get_max_days_supply()` will read the caller's groups from the identity headers
  that already pass through the proxy, and look them up in `group_overrides`. It
  will fall back to `default_max_days_supply`.

None of this lookup exists today. Entries added to `group_overrides` are ignored.

---

## Scoping Rules with `apply_to_tools`

Rules declare `params.apply_to_tools` to identify the MCP tools they govern.
These declarations supplement existing enforcement; they must not narrow a
previously tool-agnostic policy:

- Trading size, notional, cumulative exposure, cooldown, ticker and trading-window
  checks still evaluate request arguments regardless of the tool's name.
- Asset-class restrictions still use explicit `asset_class` arguments or the
  existing tool-name inference, including tools outside the declared list.
- FHIR `create` requests for `MedicationRequest` still receive controlled-substance
  checks. Neither `apply_to_tools` nor `apply_to_resource_types` can disable that
  existing protection.
- Global allow/blocklists, rate limits, token caps and time rules are unchanged.

`restricted_ticker_tool_rules` previously used `params.tools`; it now uses
`apply_to_tools` (the legacy `tools` key is still read as a fallback). This rule
was already tool-specific and retains its explicit tool matching.

Migration: add `apply_to_tools` to each rule in `rules.json` listing the intended
tools. Unlisted or renamed tools do not escape the argument-based checks above.

The proxy's enforcement is deterministic: it does not call an LLM to classify
tool descriptions or assign policies. This was also true before tool declarations
were introduced. An external LLM may choose which tool to invoke, but the proxy
independently checks the resulting request. Global `llm_rules` provide deterministic
PII filtering and token caps for chat requests, not semantic tool classification.

CI requires every per-server policy (including disabled policies) to declare a
non-empty `params.apply_to_tools`. Tool allow/blocklists already declare their
scope through `params.tools` (an empty list is permitted only when disabled).
`forbidden_endpoints` instead declares REST method/path selectors, not MCP tools.
The existing top-level generic examples and non-tool policies are exempt; new
tool policies must live under `mcp_servers`.

`tests/test_rule_tool_scopes.py` checks this configuration contract and includes
regressions for missing scopes and renamed/withdrawn tools. The Compose CI job
also initializes each configured upstream MCP server and checks every referenced
tool against its complete, paginated `tools/list`, without invoking tools or
relying on a static inventory. Missing tools fail CI, so server upgrades that
rename or remove a governed tool require a policy update. Runtime defaults for
older configurations remain unchanged.

---

## Complete Example

The shipped `rules.json` includes all six required top-level fields with a generic governance example.

1. Tool allowlist for approved read-oriented tools.
2. Tool blocklist for destructive operations.
3. Per-tool rate limits.
4. Token budgets.
5. Time-window restrictions.
6. Logging requirements.

---

## Hot Reload

1. `init_worker_by_lua_block` loads `rule_loader.lua` once per worker.
2. `rule_loader.lua` reads and validates `rules.json`.
3. A repeating 10-second timer checks for file `mtime` changes.
4. Valid updates replace the shared rules atomically.
5. Invalid updates are rejected and the previous rule set remains active.

### Live Update Example

```bash
perl -0777 -i -pe 's/"max_tokens": 4096/"max_tokens": 2048/' rules.json
```

Within 10 seconds, requests will be evaluated against the new token cap.

---

## Operational Notes

- Keep `PROVOST_TOKEN` unchanged during Phase 1.
- The governance schema in this document must match `rules.json` exactly.
- If you add fields later, document them here before relying on them operationally.
