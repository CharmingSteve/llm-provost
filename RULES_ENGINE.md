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
