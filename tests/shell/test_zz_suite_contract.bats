#!/usr/bin/env bats
# Suite contract for the Agent Provost -> LLM Provost merge.
# Named to sort last so the final TAP line reflects the merge contract.

setup() {
  ROOT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
}

@test "merge contract: trading rules ported into rules.json" {
  grep -q '"mcp_servers"' "$ROOT_DIR/rules.json"
  grep -q '"alpaca"' "$ROOT_DIR/rules.json"
  grep -q '"max_notional"' "$ROOT_DIR/rules.json"
  grep -q '"symbol_allowlist"' "$ROOT_DIR/rules.json"
  grep -q '"symbol_blocklist"' "$ROOT_DIR/rules.json"
  grep -q '"share_limits"' "$ROOT_DIR/rules.json"
  grep -q '"forbidden_endpoints"' "$ROOT_DIR/rules.json"
}

@test "merge contract: generic governance rules preserved in rules.json" {
  grep -q '"tool_allowlist"' "$ROOT_DIR/rules.json"
  grep -q '"tool_blocklist"' "$ROOT_DIR/rules.json"
  grep -q '"rate_limits"' "$ROOT_DIR/rules.json"
  grep -q '"token_caps"' "$ROOT_DIR/rules.json"
  grep -q '"time_based_rules"' "$ROOT_DIR/rules.json"
  grep -q '"logging_rules"' "$ROOT_DIR/rules.json"
  grep -q '"llm_rules"' "$ROOT_DIR/rules.json"
}

@test "merge contract: alpaca MCP wired through compose, routes, and image files" {
  grep -q "alpaca-mcp:" "$ROOT_DIR/docker-compose.yml"
  grep -q "ALPACA_IMAGE" "$ROOT_DIR/docker-compose.yml"
  grep -q "http://llm-provost:8081/trading" "$ROOT_DIR/docker-compose.yml"
  grep -q '"alpaca": "http://alpaca-mcp:8088/mcp"' "$ROOT_DIR/mcp_routes.json"
  grep -q "alpaca-mcp.Dockerfile" "$ROOT_DIR/docker-compose.override.yml"
  grep -q "ALPACA_IMAGE=" "$ROOT_DIR/.env.versions"
  [ -f "$ROOT_DIR/alpaca-mcp.Dockerfile" ]
  [ -f "$ROOT_DIR/alpaca-entrypoint.sh" ]
  [ -f "$ROOT_DIR/hash-pip/requirements-alpaca.txt" ]
  grep -q -- "--require-hashes" "$ROOT_DIR/alpaca-mcp.Dockerfile"
}

@test "merge contract: LibreChat uses the governed Alpaca MCP route" {
  grep -q 'name: "alpaca"' "$ROOT_DIR/config/librechat.yaml" || grep -q '^  alpaca:' "$ROOT_DIR/config/librechat.yaml"
  grep -q 'http://llm-provost:8000/mcp/alpaca/' "$ROOT_DIR/config/librechat.yaml"
  grep -q 'X-Provost-Token' "$ROOT_DIR/config/librechat.yaml"
  ! grep -q 'http://alpaca-mcp:8088' "$ROOT_DIR/config/librechat.yaml"
}

@test "merge contract: outbound MCP-to-API ledger present in default.conf" {
  grep -q "listen 8081;" "$ROOT_DIR/default.conf"
  grep -q "tag=provost_mcp_to_api_access" "$ROOT_DIR/default.conf"
  grep -q "paper-api.alpaca.markets" "$ROOT_DIR/default.conf"
  [ -f "$ROOT_DIR/lua/trading_rules.lua" ]
  [ -f "$ROOT_DIR/lua/alpaca_policy.lua" ]
  [ -f "$ROOT_DIR/lua/outbound_identity.lua" ]
}

@test "merge contract: unified suite completes with 0 failed governance preconditions" {
  grep -q "check_http_request" "$ROOT_DIR/lua/trading_rules.lua"
  grep -q "mcp_servers" "$ROOT_DIR/lua/rules_engine.lua"
  grep -q "pii_block" "$ROOT_DIR/lua/rules_engine.lua"
  grep -q "X-Cognito-User" "$ROOT_DIR/lua/http_policy.lua"
}
