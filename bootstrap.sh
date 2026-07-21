#!/bin/sh
set -eu

MODE="${1:-dev}"
ENV_FILE="${ENV_FILE:-.env}"
LOCAL_FALLBACK_SECRETS_DIR="${LOCAL_FALLBACK_SECRETS_DIR:-.secrets}"
MCP_ROUTES_FILE="${MCP_ROUTES_FILE:-mcp_routes.json}"

write_secret_file() {
  value="$1"
  path="$2"
  printf '%s' "$value" > "$path"
  chmod 600 "$path"
}

env_get() {
  key="$1"
  file="$2"
  awk -v key="$key" 'index($0, key "=") == 1 { print substr($0, length(key) + 2); found=1 } END { if (!found) exit 1 }' "$file"
}

emit_export_or_unset() {
  key="$1"
  value="$2"
  if [ -n "$value" ]; then
    printf "export %s='%s'\n" "$key" "$value"
  else
    printf 'unset %s\n' "$key"
  fi
}

create_runtime_dirs() {
  if [ "$MODE" = "ec2" ]; then
    PROVOST_SECRETS_DIR="${PROVOST_SECRETS_DIR:-/run/provost-secrets}"
    PROVOST_RUN_DIR="${PROVOST_RUN_DIR:-/run/provost}"
  else
    PROVOST_SECRETS_DIR="${PROVOST_SECRETS_DIR:-$(mktemp -d)}"
    PROVOST_RUN_DIR="${PROVOST_RUN_DIR:-$(mktemp -d)}"
  fi

  mkdir -p "$PROVOST_SECRETS_DIR" "$PROVOST_RUN_DIR"
  chmod 700 "$PROVOST_SECRETS_DIR"
  chmod 755 "$PROVOST_RUN_DIR"
  rm -f "$PROVOST_RUN_DIR/fluent-bit.sock"
}

create_default_routes() {
  if [ ! -f "$MCP_ROUTES_FILE" ]; then
    printf '%s\n' '{' '  "dummy": "http://mcp-server:8088"' '}' > "$MCP_ROUTES_FILE"
  fi
}

stage_local_fallback() {
  mkdir -p "$LOCAL_FALLBACK_SECRETS_DIR"
  chmod 700 "$LOCAL_FALLBACK_SECRETS_DIR"
  cp "$PROVOST_SECRETS_DIR/llm_api_key" "$LOCAL_FALLBACK_SECRETS_DIR/llm_api_key"
  cp "$PROVOST_SECRETS_DIR/provost_token" "$LOCAL_FALLBACK_SECRETS_DIR/provost_token"
  chmod 600 "$LOCAL_FALLBACK_SECRETS_DIR/llm_api_key" "$LOCAL_FALLBACK_SECRETS_DIR/provost_token"
}

create_default_routes
create_runtime_dirs

LLM_API_KEY_VALUE="${LLM_API_KEY:-}"
PROVOST_TOKEN_VALUE="${PROVOST_TOKEN:-}"
AWS_REGION_VALUE="${AWS_REGION:-}"
S3_BUCKET_VALUE="${S3_BUCKET:-}"

case "$MODE" in
  dev)
    if [ ! -f "$ENV_FILE" ]; then
      echo "echo '[bootstrap:dev] ERROR: .env file not found' >&2" >&2
      exit 1
    fi
    LLM_API_KEY_VALUE=$(env_get LLM_API_KEY "$ENV_FILE" || true)
    PROVOST_TOKEN_VALUE=$(env_get PROVOST_TOKEN "$ENV_FILE" || true)
    AWS_REGION_VALUE=$(env_get AWS_REGION "$ENV_FILE" || true)
    S3_BUCKET_VALUE=$(env_get S3_BUCKET "$ENV_FILE" || true)
    ;;
  runner)
    PROVOST_TOKEN_VALUE="${PROVOST_TOKEN_VALUE:-dummy-provost-token}"
    ;;
  ec2)
    if ! command -v aws >/dev/null 2>&1; then
      echo "echo '[bootstrap:ec2] ERROR: aws cli not found' >&2" >&2
      exit 1
    fi
    secret_name="${PROVOST_SECRET_NAME:-llm-provost/mcp}"
    AWS_REGION_VALUE="${AWS_REGION_VALUE:-us-east-1}"
    secret_json=$(aws secretsmanager get-secret-value \
      --secret-id "$secret_name" \
      --region "$AWS_REGION_VALUE" \
      --query SecretString \
      --output text)
    LLM_API_KEY_VALUE=$(printf '%s' "$secret_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("LLM_API_KEY", ""))')
    PROVOST_TOKEN_VALUE=$(printf '%s' "$secret_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("PROVOST_TOKEN", ""))')
    S3_BUCKET_VALUE=$(printf '%s' "$secret_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("S3_BUCKET", ""))')
    ;;
  *)
    echo "echo 'Usage: \$0 {dev|runner|ec2}' >&2" >&2
    exit 1
    ;;
esac

write_secret_file "$LLM_API_KEY_VALUE" "$PROVOST_SECRETS_DIR/llm_api_key"
write_secret_file "${PROVOST_TOKEN_VALUE:-dev-provost-token}" "$PROVOST_SECRETS_DIR/provost_token"

if [ "$MODE" = "dev" ] || [ "${ALLOW_EC2_LOCAL_FALLBACK_SECRETS:-false}" = "true" ]; then
  stage_local_fallback
fi

printf "export PROVOST_SECRETS_DIR='%s'\n" "$PROVOST_SECRETS_DIR"
printf "export PROVOST_RUN_DIR='%s'\n" "$PROVOST_RUN_DIR"
printf "export MCP_ROUTING_TABLE_PATH='%s'\n" '/etc/nginx/mcp_routes.json'
printf "export LLM_API_URL='%s'\n" "${LLM_API_URL:-https://api.openai.com}"
emit_export_or_unset LLM_API_KEY "$LLM_API_KEY_VALUE"
emit_export_or_unset AWS_REGION "$AWS_REGION_VALUE"
emit_export_or_unset S3_BUCKET "$S3_BUCKET_VALUE"
emit_export_or_unset AWS_ACCESS_KEY_ID "${AWS_ACCESS_KEY_ID:-}"
emit_export_or_unset AWS_SECRET_ACCESS_KEY "${AWS_SECRET_ACCESS_KEY:-}"
emit_export_or_unset AWS_SESSION_TOKEN "${AWS_SESSION_TOKEN:-}"
printf "export INSTANCE_ID='%s'\n" "${INSTANCE_ID:-local-dev}"

if [ "$MODE" != "ec2" ]; then
  printf 'trap "rm -rf '\''%s'\'' '\''%s'\''" EXIT\n' "$PROVOST_SECRETS_DIR" "$PROVOST_RUN_DIR"
fi
printf "echo '[bootstrap:%s] staged secrets/runtime dirs'\n" "$MODE"