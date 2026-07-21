#!/usr/bin/env bats

setup() {
  export TEST_REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export TEST_DIR="$(mktemp -d)"
  export PATH="$TEST_DIR/bin:$PATH"
  export PROVOST_LOG_FILE="$TEST_DIR/access.log"
  mkdir -p "$TEST_DIR/bin"

  cat > "$TEST_DIR/bin/curl" <<'EOF'
#!/bin/sh
headers_file=""
body_file=""
url=""
authorization=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dump-header) headers_file="$2"; shift 2 ;;
    --output) body_file="$2"; shift 2 ;;
    --header)
      case "$2" in
        Authorization:*) authorization="$2" ;;
      esac
      shift 2
      ;;
    --write-out|--request|--data|--connect-timeout|--max-time) shift 2 ;;
    --silent|--show-error) shift ;;
    *) url="$1"; shift ;;
  esac
done
printf 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n' > "$headers_file"
case "$url" in
  */mcp/dummy)
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"serverInfo":{"name":"dummy"}}}' > "$body_file"
    printf '%s' "${MCP_STATUS:-200}"
    ;;
  *)
    printf '%s\n' '{"error":{"message":"mock backend unavailable"}}' > "$body_file"
    printf '%s' '502'
    ;;
esac
if [ "${LEAK_AUTH:-false}" = true ]; then
  printf '%s\n' "$authorization" >> "$PROVOST_LOG_FILE"
fi
EOF
  chmod +x "$TEST_DIR/bin/curl"
  printf '%s\n' '{"request_id":"r-1","user_id":"u-1","customer_id":"c-1","conversation_id":"chat-1"}' > "$PROVOST_LOG_FILE"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "verify_proxy_routing.sh passes both paths with IDs and private logs" {
  run env PROVOST_URL=http://proxy.test sh "$TEST_REPO_ROOT/verify_proxy_routing.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS: Path A"* ]]
  [[ "$output" == *"PASS: Path B"* ]]
  [[ "$output" == *"PASS: dual-path proxy routing verified"* ]]
}

@test "verify_proxy_routing.sh fails when MCP forwarding fails" {
  run env MCP_STATUS=502 PROVOST_URL=http://proxy.test sh "$TEST_REPO_ROOT/verify_proxy_routing.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL: Path B"* ]]
}

@test "verify_proxy_routing.sh fails when four-layer IDs are absent" {
  : > "$PROVOST_LOG_FILE"
  run env PROVOST_URL=http://proxy.test sh "$TEST_REPO_ROOT/verify_proxy_routing.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL: 4-layer IDs"* ]]
}

@test "verify_proxy_routing.sh fails when authorization value reaches logs" {
  run env LEAK_AUTH=true PROVOST_URL=http://proxy.test sh "$TEST_REPO_ROOT/verify_proxy_routing.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL: Authorization header value"* ]]
}
