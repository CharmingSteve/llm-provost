#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)
COMPOSE_FILE="$PROJECT_ROOT/docker-compose.yml"
VERSIONS_FILE="$PROJECT_ROOT/.env.versions"

usage() {
	echo "Usage: $0 [--no-deps] {up|down|restart|logs|build|pull} [service ...]" >&2
	exit 2
}

if [ ! -f "$PROJECT_ROOT/.env" ]; then
	echo "WARN: $PROJECT_ROOT/.env is missing; secret-backed services may not start" >&2
fi

no_deps=false
if [ "${1:-}" = "--no-deps" ]; then
	no_deps=true
	shift
fi

mode="${1:-}"
[ -n "$mode" ] || usage
shift

if [ "$#" -eq 0 ]; then
	set -- llm-provost fluent-bit mcp-server api mongodb meilisearch
fi

compose() {
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
	*)
		usage
		;;
esac
