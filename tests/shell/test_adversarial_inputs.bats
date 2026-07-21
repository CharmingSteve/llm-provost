#!/usr/bin/env bats

setup() {
  ROOT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  CONF_FILE="$ROOT_DIR/default.conf"
  POLICY_FILE="$ROOT_DIR/lua/http_policy.lua"
  ENGINE_FILE="$ROOT_DIR/lua/rules_engine.lua"
  PROXY_FILE="$ROOT_DIR/lua/mcp_proxy.lua"
}

@test "adversarial auth: JWT parsing requires exactly three segments" {
  run grep -F 'token:match("^[^.]+%.([^.]+)%.[^.]+$")' "$POLICY_FILE"
  [ "$status" -eq 0 ]
}

@test "adversarial auth: URL-safe JWT base64 is normalized" {
  run grep -F 'gsub("-", "+"):gsub("_", "/")' "$POLICY_FILE"
  [ "$status" -eq 0 ]
}

@test "adversarial payloads: non-string tool names are not accepted as identifiers" {
  run grep -F 'type(parsed.params.name) == "string"' "$ENGINE_FILE"
  [ "$status" -eq 0 ]
}

@test "adversarial routing: destinations require HTTP or HTTPS and verify TLS" {
  run grep -F 'destination:match("^https?://")' "$PROXY_FILE"
  [ "$status" -eq 0 ]
  run grep -F 'ssl_verify = true' "$PROXY_FILE"
  [ "$status" -eq 0 ]
}

@test "adversarial payloads: client_max_body_size is set to cap oversized request bodies" {
  run grep -E 'client_max_body_size[[:space:]]+1m;' "$CONF_FILE"
  [ "$status" -eq 0 ]
}
