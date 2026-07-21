#!/usr/bin/env bats
# tests/shell/test_entrypoint.bats
# Unit tests for entrypoint.sh and verify_proxy_routing.sh.
# These tests inspect script content and structure; they do not execute the
# scripts (which require a live Docker / Python environment).

# ── entrypoint.sh ────────────────────────────────────────────────────────────

@test "entrypoint.sh: strict error handling is enabled" {
    run grep -c "^set -eu" entrypoint.sh
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

@test "entrypoint.sh: does not patch legacy upstream settings" {
    run grep -E "MCP_API_KEY|MCP_SECRET_KEY|MCP_PAPER_TRADE|MCP_API_URL" entrypoint.sh
    [ "$status" -eq 1 ]
}

@test "entrypoint.sh: starts MCP server on port 8088" {
    run grep -c "\-\-port 8088" entrypoint.sh
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

@test "entrypoint.sh: uses streamable-http transport" {
    run grep -c "streamable-http" entrypoint.sh
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

@test "entrypoint.sh: binds server to 0.0.0.0 (all interfaces)" {
    run grep -c "\-\-host 0.0.0.0" entrypoint.sh
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

@test "entrypoint.sh: uses exec to replace the shell process (no zombie)" {
    run grep -c "^exec " entrypoint.sh
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

# ── verify_proxy_routing.sh ──────────────────────────────────────────────────

@test "verify_proxy_routing.sh: strict error handling is enabled (set -e)" {
    run grep -c "^set -e" verify_proxy_routing.sh
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

@test "verify_proxy_routing.sh: validates fluent-bit health before probe" {
    run grep -c "wait_for_fluentbit_health\|fluent-bit health" verify_proxy_routing.sh
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

@test "verify_proxy_routing.sh: validates socket path in shared runtime dir" {
    run grep -c "fluent-bit.sock\|socket present" verify_proxy_routing.sh
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

@test "verify_proxy_routing.sh: supports S3 audit evidence check" {
    run grep -c "check_s3_for_probe\|VERIFY_S3_BUCKET\|llm-provost/logs" verify_proxy_routing.sh
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

@test "verify_proxy_routing.sh: supports buffer fallback evidence check" {
    run grep -c "check_buffer_evidence\|fluent-bit buffer" verify_proxy_routing.sh
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

@test "verify_proxy_routing.sh: embeds unique probe request id marker" {
    run grep -c "PROBE_ID\|X-Provost-Request-Id\|PROVOST_VERIFY_REQUEST_ID" verify_proxy_routing.sh
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

@test "verify_proxy_routing.sh: can force S3-only or buffer-only mode" {
    run grep -c "VERIFY_REQUIRE_S3\|true)\|false)\|auto)" verify_proxy_routing.sh
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

@test "verify_proxy_routing.sh: reports PASS for fluent-bit audit path" {
    run grep -c "PASS: fluent-bit socket/audit path validated" verify_proxy_routing.sh
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

@test "verify_proxy_routing.sh: probes the MCP endpoint on port 8088" {
    run grep -c "localhost:8088" verify_proxy_routing.sh
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

# ── bootstrap.sh ─────────────────────────────────────────────────────────────

@test "bootstrap.sh: creates a default MCP routing table" {
    run grep -c "^create_default_routes()" bootstrap.sh
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

@test "bootstrap.sh: ec2 fallback copy requires explicit ALLOW_EC2_LOCAL_FALLBACK_SECRETS" {
    run grep -c 'ALLOW_EC2_LOCAL_FALLBACK_SECRETS' bootstrap.sh
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

@test "bootstrap.sh: stages the LLM API key without legacy MCP credentials" {
    run grep -c 'LLM_API_KEY' bootstrap.sh
    [ "$status" -eq 0 ]
    [ "$output" -ge 3 ]
    run grep -E 'MCP_API_KEY|MCP_SECRET_KEY|MCP_PAPER_TRADE' bootstrap.sh
    [ "$status" -eq 1 ]
}
