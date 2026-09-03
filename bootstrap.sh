#!/bin/sh
set -eu

MODE="${1:-container}"
ENV_FILE="${ENV_FILE:-.env}"
MCP_ROUTES_FILE="${MCP_ROUTES_FILE:-mcp_routes.json}"
SECRET_KEYS="LLM_API_KEY OPENID_CLIENT_ID OPENID_CLIENT_SECRET OPENID_SESSION_SECRET MEILI_MASTER_KEY"

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

create_default_routes() {
  if [ ! -f "$MCP_ROUTES_FILE" ]; then
    printf '%s\n' '{' '  "dummy": "http://mcp-server:8088/mcp",' '  "alpaca": "http://alpaca-mcp:8088/mcp"' '}' > "$MCP_ROUTES_FILE"
  fi
}

write_secret_file() {
  value="$1"
  path="$2"
  printf '%s' "$value" > "$path"
  chmod 600 "$path"
}

create_runtime_dirs() {
  mode="$1"
  if [ "$mode" = "ec2" ]; then
    PROVOST_SECRETS_DIR="/run/provost-secrets"
    PROVOST_RUN_DIR="/run/provost"
    mkdir -p "$PROVOST_SECRETS_DIR" "$PROVOST_RUN_DIR"
  else
    if [ -z "${PROVOST_SECRETS_DIR:-}" ] || [ ! -d "$PROVOST_SECRETS_DIR" ]; then
      PROVOST_SECRETS_DIR=$(mktemp -d)
    fi
    if [ -z "${PROVOST_RUN_DIR:-}" ] || [ ! -d "$PROVOST_RUN_DIR" ]; then
      PROVOST_RUN_DIR=$(mktemp -d)
    fi
  fi
  chmod 700 "$PROVOST_SECRETS_DIR"
  chmod 700 "$PROVOST_RUN_DIR"
}

stage_runtime_secrets() {
  mode="$1"
  create_runtime_dirs "$mode"
  write_secret_file "${ALPACA_API_KEY:-dummy}" "$PROVOST_SECRETS_DIR/alpaca_api_key"
  write_secret_file "${ALPACA_SECRET_KEY:-dummy}" "$PROVOST_SECRETS_DIR/alpaca_secret_key"
  write_secret_file "${ALPACA_PAPER_TRADE:-true}" "$PROVOST_SECRETS_DIR/alpaca_paper_trade"
  write_secret_file "${PROVOST_TOKEN:-dummy-provost-token}" "$PROVOST_SECRETS_DIR/provost_token"
}

# Stage the Alpaca MCP server's file-based secrets (mounted at /run/secrets)
# so alpaca-mcp can start and the forbidden-endpoint integration test can
# authenticate against the outbound ledger.
stage_alpaca_secrets() {
  if [ -z "${PROVOST_SECRETS_DIR:-}" ] || [ ! -d "$PROVOST_SECRETS_DIR" ]; then
    PROVOST_SECRETS_DIR=$(mktemp -d)
  fi
  chmod 700 "$PROVOST_SECRETS_DIR"
  write_secret_file "${ALPACA_API_KEY:-dummy}" "$PROVOST_SECRETS_DIR/alpaca_api_key"
  write_secret_file "${ALPACA_SECRET_KEY:-dummy}" "$PROVOST_SECRETS_DIR/alpaca_secret_key"
  write_secret_file "${ALPACA_PAPER_TRADE:-true}" "$PROVOST_SECRETS_DIR/alpaca_paper_trade"
}

json_get() {
  key="$1"
  python3 -c 'import json, sys; print(json.load(sys.stdin).get(sys.argv[1], ""))' "$key"
}

load_env_file() {
  if [ ! -f "$ENV_FILE" ]; then
    echo "[bootstrap] WARN: $ENV_FILE is missing; using environment values" >&2
    return
  fi

  for key in $SECRET_KEYS AWS_REGION S3_BUCKET LLM_ROUTES_JSON PROVOST_TOKEN ALPACA_API_KEY ALPACA_SECRET_KEY ALPACA_PAPER_TRADE; do
    value=$(env_get "$key" "$ENV_FILE" || true)
    if [ -n "$value" ]; then
      export "$key=$value"
    fi
  done
}

load_secrets_manager() {
  if ! command -v aws >/dev/null 2>&1; then
    echo "[bootstrap] ERROR: aws cli is required for Secrets Manager" >&2
    exit 1
  fi

  secret_name="${PROVOST_SECRET_NAME:-llm-provost/application}"
  region="${AWS_REGION:-us-east-1}"
  secret_json=$(aws secretsmanager get-secret-value \
    --secret-id "$secret_name" \
    --region "$region" \
    --query SecretString \
    --output text)

  for key in $SECRET_KEYS PROVOST_TOKEN ALPACA_API_KEY ALPACA_SECRET_KEY ALPACA_PAPER_TRADE; do
    value=$(printf '%s' "$secret_json" | json_get "$key")
    if [ -n "$value" ]; then
      export "$key=$value"
    fi
  done

  s3_bucket=$(printf '%s' "$secret_json" | json_get S3_BUCKET)
  if [ -n "$s3_bucket" ]; then
    export S3_BUCKET="$s3_bucket"
  fi
}

emit_environment() {
  for key in $SECRET_KEYS AWS_REGION S3_BUCKET LLM_ROUTES_JSON PROVOST_TOKEN ALPACA_API_KEY ALPACA_SECRET_KEY ALPACA_PAPER_TRADE; do
    eval "value=\${$key:-}"
    emit_export_or_unset "$key" "$value"
  done
}

case "$MODE" in
  dev)
    create_default_routes
    load_env_file
    stage_runtime_secrets dev
    echo "export PROVOST_SECRETS_DIR='$PROVOST_SECRETS_DIR'"
    echo "export PROVOST_RUN_DIR='$PROVOST_RUN_DIR'"
    emit_environment
    echo "trap \"rm -rf '$PROVOST_SECRETS_DIR' '$PROVOST_RUN_DIR'\" EXIT"
    ;;
  runner)
    create_default_routes
    stage_runtime_secrets runner
    emit_environment
    echo "export PROVOST_SECRETS_DIR='$PROVOST_SECRETS_DIR'"
    echo "export PROVOST_RUN_DIR='$PROVOST_RUN_DIR'"
    ;;
  ec2)
    create_default_routes
    load_env_file
    load_secrets_manager
    stage_runtime_secrets ec2
    emit_environment
    echo "export PROVOST_SECRETS_DIR='$PROVOST_SECRETS_DIR'"
    echo "export PROVOST_RUN_DIR='$PROVOST_RUN_DIR'"
    ;;
  container)
    load_env_file
    if [ "${PROVOST_RUNTIME:-local}" = "ec2" ]; then
      load_secrets_manager
    fi
    exec openresty -g 'daemon off;' -c /etc/nginx/conf.d/default.conf
    ;;
  *)
    echo "Usage: $0 {dev|runner|ec2}" >&2
    exit 1
    ;;
esac