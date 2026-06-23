#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${MIRROR_ENV_FILE:-/etc/njxzu-mirrors.env}"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

MIRROR_ROOT="${MIRROR_ROOT:-/srv/mirror}"
mkdir -p "$MIRROR_ROOT"
touch "$MIRROR_ROOT/.sync-trigger"

if [[ "${MIRROR_DEPLOY_MODE:-}" == "container" ]]; then
  COMPOSE_FILE="${MIRROR_CONTAINER_COMPOSE_FILE:-/opt/njxzu-mirrors-index/deploy/compose.yaml}"
  COMPOSE_ENV="${MIRROR_CONTAINER_COMPOSE_ENV:-}"
  compose_cmd=(docker compose)
  if [[ -n "$COMPOSE_ENV" && -f "$COMPOSE_ENV" ]]; then
    compose_cmd+=(--env-file "$COMPOSE_ENV")
  fi
  compose_cmd+=(-f "$COMPOSE_FILE")
  "${compose_cmd[@]}" exec -T index /app/scripts/generate-index.sh >/dev/null 2>&1 || true
  exit 0
fi

if command -v systemctl >/dev/null 2>&1; then
  systemctl start mirrors-index.service >/dev/null 2>&1 || true
fi
