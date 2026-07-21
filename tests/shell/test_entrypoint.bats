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
    run grep -c '^PORT = 8088$' mcp_server/server.py
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

@test "entrypoint.sh: starts the JSON-RPC HTTP server" {
    run grep -c 'ThreadingHTTPServer' mcp_server/server.py
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

@test "entrypoint.sh: binds server to 0.0.0.0 (all interfaces)" {
    run grep -c '^HOST = "0.0.0.0"$' mcp_server/server.py
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

@test "verify_proxy_routing.sh: probes Path A chat completions" {
    run grep -c 'v1/chat/completions' verify_proxy_routing.sh
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

@test "verify_proxy_routing.sh: probes Path B dummy MCP" {
    run grep -c 'mcp/dummy' verify_proxy_routing.sh
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

@test "verify_proxy_routing.sh: sends JSON-RPC initialize" {
    run grep -c '"method":"initialize"' verify_proxy_routing.sh
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

@test "verify_proxy_routing.sh: checks all four IDs" {
    run grep -c 'request_id.*user_id.*customer_id.*conversation_id\|user_id.*customer_id.*conversation_id.*request_id' verify_proxy_routing.sh
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

@test "verify_proxy_routing.sh: uses curl for requests" {
    run grep -c 'curl --silent' verify_proxy_routing.sh
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

@test "verify_proxy_routing.sh: checks Authorization log privacy" {
    run grep -c 'Authorization header value' verify_proxy_routing.sh
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

@test "verify_proxy_routing.sh: reports PASS for dual routing" {
    run grep -c 'PASS: dual-path proxy routing verified' verify_proxy_routing.sh
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

@test "verify_proxy_routing.sh: defaults to proxy port 8000" {
    run grep -c 'localhost:8000' verify_proxy_routing.sh
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

# ── bootstrap.sh ─────────────────────────────────────────────────────────────

@test "bootstrap.sh: creates a default MCP routing table" {
    run grep -c "^create_default_routes()" bootstrap.sh
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

@test "bootstrap.sh: loads production secrets from Secrets Manager" {
    run grep -c 'aws secretsmanager get-secret-value' bootstrap.sh
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

@test "bootstrap.sh: handles LLM and Cognito secrets without legacy MCP credentials" {
    run grep -c 'LLM_API_KEY OPENID_CLIENT_ID OPENID_CLIENT_SECRET OPENID_SESSION_SECRET MEILI_MASTER_KEY' bootstrap.sh
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
    run grep -E 'MCP_API_KEY|MCP_SECRET_KEY|MCP_PAPER_TRADE' bootstrap.sh
    [ "$status" -eq 1 ]
}

@test "bootstrap.sh: starts OpenResty in container mode" {
    run grep -c "exec openresty -g 'daemon off;'" bootstrap.sh
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}
