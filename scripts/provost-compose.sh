#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)
COMPOSE_FILE="$PROJECT_ROOT/docker-compose.yml"
VERSIONS_FILE="$PROJECT_ROOT/.env.versions"

usage() {
	echo "Usage: $0 [--no-deps] {up|down|restart|logs|build|pull|ps} [options|service ...]" >&2
	exit 2
}

cd "$PROJECT_ROOT"

# Docker Compose parses .env as a dotenv file; do not source it as shell code.
# CI and production provide values through their environment or bootstrap.
if [ -f "$PROJECT_ROOT/.env" ]; then
	:
else
	echo "WARN: $PROJECT_ROOT/.env is missing; using environment values" >&2
fi

no_deps=false
if [ "${1:-}" = "--no-deps" ]; then
	no_deps=true
	shift
fi

mode="${1:-}"
[ -n "$mode" ] || usage
shift

if [ "$#" -eq 0 ] && [ "$mode" != "ps" ]; then
	set -- llm-provost fluent-bit mcp-server alpaca-mcp api mongodb meilisearch
fi

compose() {
	if [ -f "$PROJECT_ROOT/.env" ]; then
		docker compose --env-file "$VERSIONS_FILE" --env-file "$PROJECT_ROOT/.env" -f "$COMPOSE_FILE" "$@"
		return
	fi

	docker compose --env-file "$VERSIONS_FILE" -f "$COMPOSE_FILE" "$@"
}

case "$mode" in
	up)
		if [ "$no_deps" = true ]; then
			compose up -d --no-deps llm-provost
		else
			compose up -d "$@"
		fi
		;;
	down)
		compose down --remove-orphans
		;;
	restart)
		if [ "$no_deps" = true ]; then
			compose up -d --force-recreate --no-deps llm-provost
		else
			compose restart "$@"
		fi
		;;
	logs)
		compose logs -f "$@"
		;;
	build)
		compose build "$@"
		;;
	pull)
		compose pull "$@"
		;;
	ps)
		compose ps "$@"
		;;
	*)
		usage
		;;
esac
