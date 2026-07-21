#!/bin/sh
set -eu

echo "[entrypoint] Starting LLM Provost dummy MCP server..."
exec python /app/mcp_server/server.py