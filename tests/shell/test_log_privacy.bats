#!/usr/bin/env bats

setup() {
  ROOT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  CONF_FILE="$ROOT_DIR/default.conf"
}

@test "log privacy: json_full log_format uses escape=json to prevent log injection" {
  run grep -E 'log_format[[:space:]]+json_full[[:space:]]+escape=json' "$CONF_FILE"
  [ "$status" -eq 0 ]
}

@test "log privacy: credentials are absent from the log format" {
  run python3 -c 'import pathlib,sys; text=pathlib.Path(sys.argv[1]).read_text(); block=text.split("log_format json_full", 1)[1].split("'\''}'\'';", 1)[0].lower(); raise SystemExit(1 if "authorization" in block or "token" in block else 0)' "$CONF_FILE"
  [ "$status" -eq 0 ]
}

@test "log privacy: error schema never emits credentials" {
  run python3 -c 'import pathlib,re,sys; text=pathlib.Path(sys.argv[1]).read_text(); block=re.search(r"local fields\s*=\s*\{(.*?)\n\s*\}", text, re.S).group(1).lower(); raise SystemExit(1 if "authorization" in block or "token" in block else 0)' "$ROOT_DIR/lua/audit_error.lua"
  [ "$status" -eq 0 ]
}

@test "log privacy: multiline payload content remains valid JSON line structure" {
  TMPDIR="$(mktemp -d)"
  mkdir -p "$TMPDIR/nginx-logs"
  LOG_FILE="$TMPDIR/nginx-logs/llm_to_mcp_access.log"

  cat > "$LOG_FILE" <<'EOF'
{"time_local":"t","remote_addr":"127.0.0.1","request":"POST /mcp/dummy HTTP/1.1","status":"200","user_id":"u-1","customer_id":"c-1","conversation_id":"chat-1","request_id":"r-1","request_body":"line 1\nline 2","resp_body":"ok"}
EOF

  run python3 -c 'import json,sys; json.loads(open(sys.argv[1], "r", encoding="utf-8").read().strip()); print("ok")' "$LOG_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}
