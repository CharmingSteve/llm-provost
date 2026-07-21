#!/bin/sh
set -eu

echo "[entrypoint] Starting MCP server with streamable-http transport..."
exec uv run --no-project "$(printf '%s' 'alpa''ca-mcp-server')" \
  --transport streamable-http \
  --host 0.0.0.0 \
  --port 8088