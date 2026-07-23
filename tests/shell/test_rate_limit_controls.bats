#!/usr/bin/env bats

setup() {
  ROOT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  CONF_FILE="$ROOT_DIR/default.conf"
  RULES_FILE="$ROOT_DIR/rules.json"
  ENGINE_FILE="$ROOT_DIR/lua/rules_engine.lua"
  LIMIT_FILE="$ROOT_DIR/lua/rate_limit.lua"
}

@test "rate limit controls: shared dict is configured" {
  run grep -q "lua_shared_dict rate_limit 1m;" "$CONF_FILE"
  [ "$status" -eq 0 ]
}

@test "rate limit controls: default rules include per-tool limits" {
  run grep -q '"rate_limits"' "$RULES_FILE"
  [ "$status" -eq 0 ]
}

@test "rate limit controls: rules engine delegates per-tool counters" {
  run grep -q 'is_tool_rate_exceeded' "$ENGINE_FILE"
  [ "$status" -eq 0 ]
}

@test "rate limit controls: limiter scopes counters by user and tool" {
  run grep -q '"tool_rate:" .. user .. ":" .. tool' "$LIMIT_FILE"
  [ "$status" -eq 0 ]
}
