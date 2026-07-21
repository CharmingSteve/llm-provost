#!/usr/bin/env bats

setup() {
  ROOT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  POLICY_FILE="$ROOT_DIR/lua/http_policy.lua"
  COMPOSE_FILE="$ROOT_DIR/docker-compose.yml"
}

@test "dual auth: MCP requests use the Cognito user header" {
  run grep -q 'X-Cognito-User' "$POLICY_FILE"
  [ "$status" -eq 0 ]
}

@test "dual auth: chat requests decode Bearer JWT claims" {
  run grep -q 'Bearer' "$POLICY_FILE"
  [ "$status" -eq 0 ]
  run grep -q 'claims.sub or claims.email' "$POLICY_FILE"
  [ "$status" -eq 0 ]
}

@test "dual auth: static compatibility token is not used by Lua" {
  run grep -R 'PROVOST_TOKEN' "$ROOT_DIR/lua" --include='*.lua'
  [ "$status" -eq 1 ]
}

@test "dual auth: compatibility token remains available to compose" {
  run grep -q 'PROVOST_TOKEN:' "$COMPOSE_FILE"
  [ "$status" -eq 0 ]
}

@test "dual auth: user and conversation defaults are present" {
  run grep -q 'user_id = "steve"' "$POLICY_FILE"
  [ "$status" -eq 0 ]
  run grep -q 'conversation_id = "none"' "$POLICY_FILE"
  [ "$status" -eq 0 ]
}

@test "dual auth: customer ID can come from ID or name arguments" {
  run grep -q 'arguments.customer_id or arguments.customer_name' "$POLICY_FILE"
  [ "$status" -eq 0 ]
}