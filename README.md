# LLM Provost: Governance Proxy and Audit Ledger for LLM Interactions

<p align="center">
   <img src="llm-provost-1-Copilot_20260526_195647.png" alt="LLM Provost lock-eye emblem" width="360" />
</p>

> LLM Provost: guardrails for MCP-mediated LLM interactions

**LLM Provost** is a high-performance, mandatory MITM boundary for **LLM governance** and **audited MCP traffic**. It sits between your LLM client, your Model Context Protocol server, and the upstream tool or API layer so every request can be observed, logged, and policy-checked before it leaves your trust boundary.

Use it when you need programmable guardrails, identity-aware audit trails, and rapid policy updates without restarting the proxy.

**👉 Launch on AWS Marketplace:** [LLM Provost AMI](https://aws.amazon.com/marketplace/pp/prodview-ouyql6wbwo6yg)

---

## Quickstart (TLDR)

## AWS Marketplace Deployment & Usage

LLM Provost is designed to run as a secure, stateless appliance inside your AWS account.

### Step 1: Deploy the Appliance
1. Subscribe to LLM Provost on AWS Marketplace and launch the CloudFormation template.
2. Fill in the deployment parameters, including your `PROVOST_TOKEN` and the governance policy you want enforced at the proxy boundary.
3. Wait for the stack to reach `CREATE_COMPLETE`.
4. Open the CloudFormation Outputs tab and copy the public IP address for the appliance.

### Step 2: Connect Your AI Client
LLM Provost acts as a remote MCP server. Point your MCP client at the instance IP and authenticate with the same `PROVOST_TOKEN` you provided at deploy time.

#### For Claude Desktop
```json
{
  "mcpServers": {
    "llm-provost": {
      "type": "sse",
      "url": "http://<YOUR_EC2_PUBLIC_IP>:8000/sse",
      "env": {
        "PROVOST_TOKEN": "<YOUR_PROVOST_TOKEN>",
        "PROVOST_USER": "claude-desktop",
        "PROVOST_MACHINE": "work-laptop"
      }
    }
  }
}
```

#### For Cursor
```json
{
  "mcpServers": {
    "llm-provost": {
      "type": "sse",
      "url": "http://<YOUR_EC2_PUBLIC_IP>:8000/sse",
      "env": {
        "PROVOST_TOKEN": "<YOUR_PROVOST_TOKEN>",
        "PROVOST_USER": "cursor-ide",
        "PROVOST_MACHINE": "dev-machine"
      }
    }
  }
}
```

### Step 3: Verify Policy Enforcement
1. Restart your MCP client.
2. Ask the client to list available tools through the remote MCP server.
3. Attempt a blocked operation such as `delete_record` or `export_full_database`.
4. Confirm that LLM Provost denies the request and records the attempt in the audit logs.

***

# For installing manually from this repo

Clone and run locally:

```sh
git clone https://github.com/CharmingSteve/llm-provost.git
cd llm-provost
unset PROVOST_SECRETS_DIR
docker compose down
eval "$(sh bootstrap.sh dev)"
docker compose --env-file .env.versions up -d
docker exec llm-provost cat /run/secrets/provost_token
```

Phase 1 keeps the current upstream compatibility environment variables and secret staging flow used by the existing compose stack. `PROVOST_TOKEN` remains the client-facing authentication secret for this phase.

## Key Features for AI Safety & Compliance

- **Programmable governance guardrails:** Allow or block tool invocations based on policy.
- **Per-tool rate limiting:** Slow down abusive or runaway automation before it fans out.
- **Token caps:** Enforce response-size limits at the boundary.
- **Time-based access controls:** Restrict sensitive tools to approved hours and time zones.
- **Identity-aware audit ledger:** Carry `PROVOST_USER`, `PROVOST_MACHINE`, and correlation IDs across hops.
- **Hot-reload rules:** Update policy by editing `rules.json`; the proxy reloads changes within 10 seconds.
- **Dockerized deployment:** Run the proxy, MCP server, and log shipper as a compact compose stack.

---

## Architecture: The Two-Hop Flow

LLM Provost monitors two distinct boundaries:

1. **llm-to-mcp (Inbound):** `LLM Client` -> `LLM Provost (Port 8000)` -> `MCP Server`
2. **mcp-to-upstream (Outbound):** `MCP Server` -> `LLM Provost (Port 8081)` -> `Approved tool or API layer`

This double-proxy layout preserves an end-to-end record of each governed interaction while letting you enforce policy before outbound calls leave the trust boundary.

### Four-Step Audit Model

For a normal governed request, you should be able to correlate:

1. LLM client request to the proxy
2. MCP server request leaving the proxy
3. Upstream response returning through the proxy
4. Final response sent back to the LLM client

The shared correlation fields are:

- `provost_user`
- `provost_machine`
- `provost_request_id`

---

## Safety Controls & Governance

LLM Provost enforces policy from `rules.json` on every request. The Phase 1 governance schema is:

- `tool_allowlist`: Explicitly permitted MCP tools.
- `tool_blocklist`: Explicitly denied MCP tools.
- `rate_limits`: Per-tool request windows.
- `token_caps`: Maximum token budgets per request.
- `time_based_rules`: Tool-specific hour windows with time zone handling.
- `logging_rules`: Required audit fields and logging behavior.

See [RULES_ENGINE.md](RULES_ENGINE.md) for the full schema and example policies.

### Example Governance Posture

A realistic governance policy can:

- permit `get_records`, `list_items`, and `summarize_report`
- deny `delete_record` and `export_full_database`
- limit record lookups to 10 calls per minute per user
- cap `max_tokens` to 4096 per request
- allow `export_summary` only during business hours

---

## Audit Log Layout

Local development defaults use the `llm-provost-local` bucket name, and shipped audit objects are stored under the `llm-provost/logs/` prefix. This keeps branding, compose defaults, and CloudFormation outputs aligned.

## Operations Notes

- `PROVOST_TOKEN` is intentionally unchanged in Phase 1.
- Policy reloads are driven by a 10-second file `mtime` poll; no nginx reload is required.
- If `rules.json` becomes invalid, the last good policy remains active.

## Support

Open an issue or discussion in the repository if you need a different governance policy model or a more restrictive deployment posture for your environment.
