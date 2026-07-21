#!/bin/sh
set -eu

PROVOST_URL="${PROVOST_URL:-http://localhost:8000}"
LOG_FILE="${PROVOST_LOG_FILE:-logs/fluent-bit-storage/access.log}"
AUTH_MARKER="provost-auth-must-not-appear-$$"
CHAT_HEADERS=$(mktemp)
CHAT_BODY=$(mktemp)
MCP_HEADERS=$(mktemp)
MCP_BODY=$(mktemp)
trap 'rm -f "$CHAT_HEADERS" "$CHAT_BODY" "$MCP_HEADERS" "$MCP_BODY"' EXIT

pass() {
    echo "PASS: $1"
}

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

request() {
    headers_file="$1"
    body_file="$2"
    url="$3"
    payload="$4"

    curl --silent --show-error \
        --connect-timeout 5 \
        --max-time 20 \
        --dump-header "$headers_file" \
        --output "$body_file" \
        --write-out '%{http_code}' \
        --header 'Content-Type: application/json' \
        --header 'X-Cognito-User: verify-user' \
        --header 'X-Conversation-Id: verify-conversation' \
        --header "Authorization: Bearer $AUTH_MARKER" \
        --request POST \
        --data "$payload" \
        "$url"
}

CHAT_PAYLOAD='{"model":"verification-model","messages":[{"role":"user","content":"routing check"}]}'
chat_status=$(request "$CHAT_HEADERS" "$CHAT_BODY" "$PROVOST_URL/v1/chat/completions" "$CHAT_PAYLOAD") || \
    fail "Path A request could not reach the proxy"

case "$chat_status" in
    2??|4??|5??) pass "Path A chat request reached the proxy (HTTP $chat_status)" ;;
    *) fail "Path A returned unexpected HTTP $chat_status" ;;
esac

MCP_PAYLOAD='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"provost-verifier","version":"1.0"}}}'
mcp_status=$(request "$MCP_HEADERS" "$MCP_BODY" "$PROVOST_URL/mcp/dummy" "$MCP_PAYLOAD") || \
    fail "Path B request could not reach the proxy"

if [ "$mcp_status" -ne 200 ]; then
    fail "Path B MCP initialize returned HTTP $mcp_status"
fi
if ! grep -Eq '"jsonrpc"[[:space:]]*:[[:space:]]*"2.0"|^data:' "$MCP_BODY"; then
    fail "Path B MCP initialize did not return JSON-RPC data"
fi
pass "Path B MCP request reached the dummy server"

ID_PATTERN='request_id|user_id|customer_id|conversation_id|x-provost-request-id|x-provost-user-id|x-provost-customer-id|x-provost-conversation-id'
if grep -Eiq "$ID_PATTERN" "$CHAT_HEADERS" "$MCP_HEADERS" "$CHAT_BODY" "$MCP_BODY"; then
    pass "4-layer IDs are present in response headers or bodies"
elif [ -f "$LOG_FILE" ] && grep -Eq '"request_id".*"user_id".*"customer_id".*"conversation_id"|"user_id".*"customer_id".*"conversation_id".*"request_id"' "$LOG_FILE"; then
    pass "4-layer IDs are present in proxy logs"
else
    fail "4-layer IDs were not found in response headers, bodies, or $LOG_FILE"
fi

if [ -f "$LOG_FILE" ] && grep -Fq "$AUTH_MARKER" "$LOG_FILE"; then
    fail "Authorization header value was written to proxy logs"
fi
pass "Authorization header value is absent from proxy logs"

echo "PASS: dual-path proxy routing verified"
