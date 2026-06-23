#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DOMAIN="${MIRROR_DOMAIN:-mirrors.njxzc.edu.cn}"
EMAIL="${MIRROR_CONTACT_EMAIL:-mirror-admin@njxzc.edu.cn}"
WEB_ROOT="${MIRROR_WEB_ROOT:-/srv/mirror/www}"
SRC_DIR="${MIRROR_SRC_DIR:-/opt/njxzu-mirrors-index}"
CONTAINER_ENV="${MIRROR_CONTAINER_ENV_FILE:-/etc/njxzu-mirrors-container.env}"
YUKI_ENV="${MIRROR_ENV_FILE:-/etc/njxzu-mirrors.env}"
INSTALL_WEB=1
INSTALL_YUKI=1

usage() {
  cat <<EOF
Usage: sudo $0 [options]

Install NJXZU Mirrors with web/index in containers and yuki on the host.

Options:
  --domain DOMAIN        Mirror domain. Default: $DOMAIN
  --email EMAIL          Contact email. Default: $EMAIL
  --web-root PATH        Shared mirror web root. Default: $WEB_ROOT
  --src-dir PATH         Install source directory. Default: $SRC_DIR
  --container-env PATH   Compose env file. Default: $CONTAINER_ENV
  --yuki-env PATH        Host yuki env file. Default: $YUKI_ENV
  --skip-web            Do not deploy web/index containers.
  --skip-yuki           Do not install host yuki.
  --help                Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="$2"; shift 2 ;;
    --email) EMAIL="$2"; shift 2 ;;
    --web-root) WEB_ROOT="$2"; shift 2 ;;
    --src-dir) SRC_DIR="$2"; shift 2 ;;
    --container-env) CONTAINER_ENV="$2"; shift 2 ;;
    --yuki-env) YUKI_ENV="$2"; shift 2 ;;
    --skip-web) INSTALL_WEB=0; shift ;;
    --skip-yuki) INSTALL_YUKI=0; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run as root: sudo $0" >&2
  exit 1
fi

write_env_file() {
  local path="$1"
  shift
  install -d "$(dirname "$path")"
  : > "$path"
  while [[ $# -gt 0 ]]; do
    printf '%s=%s\n' "$1" "$2" >> "$path"
    shift 2
  done
}

write_env_file "$CONTAINER_ENV" \
  MIRROR_NAME NJXZU \
  MIRROR_DOMAIN "$DOMAIN" \
  MIRROR_BASE_URL "https://$DOMAIN" \
  MIRROR_CONTACT_EMAIL "$EMAIL" \
  MIRROR_WEB_ROOT "$WEB_ROOT" \
  MIRROR_HELP_URL "https://help.mirrors.cernet.edu.cn/" \
  MIRROR_STATUS_URL "/status/" \
  MIRROR_STATUS_JSON_URL "/status/json" \
  MIRROR_ABOUT_URL "https://www.njxzc.edu.cn/" \
  MIRROR_NEWS_URL "" \
  MIRROR_NEWS_FEED "" \
  MIRROR_REQUEST_URL "mailto:$EMAIL?subject=New%20mirror%20request" \
  MIRROR_ISSUE_URL "mailto:$EMAIL?subject=Mirror%20issue" \
  YUKI_PROXY_URL "http://127.0.0.1:9999" \
  MIRROR_YUKI_URL "http://127.0.0.1:9999/api/v1/metas" \
  MIRROR_INDEX_INTERVAL "600"

write_env_file "$YUKI_ENV" \
  MIRROR_NAME NJXZU \
  MIRROR_DOMAIN "$DOMAIN" \
  MIRROR_BASE_URL "https://$DOMAIN" \
  MIRROR_CONTACT_EMAIL "$EMAIL" \
  MIRROR_ROOT "$(dirname "$WEB_ROOT")" \
  MIRROR_WEB_ROOT "$WEB_ROOT" \
  MIRROR_HTTPDIR "$WEB_ROOT" \
  MIRROR_OUTDIR "$WEB_ROOT" \
  MIRROR_SRC_DIR "$SRC_DIR" \
  MIRROR_USER mirror \
  MIRROR_GROUP mirror \
  MIRROR_HELP_URL "https://help.mirrors.cernet.edu.cn/" \
  MIRROR_STATUS_URL "/status/" \
  MIRROR_STATUS_JSON_URL "/status/json" \
  MIRROR_ABOUT_URL "https://www.njxzc.edu.cn/" \
  MIRROR_NEWS_URL "" \
  MIRROR_NEWS_FEED "" \
  MIRROR_REQUEST_URL "mailto:$EMAIL?subject=New%20mirror%20request" \
  MIRROR_ISSUE_URL "mailto:$EMAIL?subject=Mirror%20issue" \
  YUKI_LISTEN "127.0.0.1:9999" \
  MIRROR_YUKI_URL "http://127.0.0.1:9999/api/v1/metas" \
  YUKI_CONFIG_DIR "/etc/yuki/repos" \
  YUKI_LOG_DIR "/var/log/yuki" \
  YUKI_DB "/var/lib/yuki/yukid.db" \
  MIRROR_DEPLOY_MODE container \
  MIRROR_CONTAINER_COMPOSE_FILE "$SRC_DIR/deploy/compose.yaml" \
  MIRROR_CONTAINER_COMPOSE_ENV "$CONTAINER_ENV"

if [[ "$INSTALL_WEB" == "1" ]]; then
  MIRROR_CONTAINER_ENV_FILE="$CONTAINER_ENV" \
  MIRROR_ENV_FILE="$YUKI_ENV" \
  MIRROR_SRC_DIR="$SRC_DIR" \
  "$SCRIPT_DIR/container-deploy.sh"
fi

if [[ "$INSTALL_YUKI" == "1" ]]; then
  MIRROR_ENV_FILE="$YUKI_ENV" "$SCRIPT_DIR/setup-yuki.sh"
fi

cat <<EOF
Install complete.

Domain:        $DOMAIN
Web root:      $WEB_ROOT
Source dir:    $SRC_DIR
Container env: $CONTAINER_ENV
Yuki env:      $YUKI_ENV

Add an rsync repository:
  sudo $SRC_DIR/deploy/add-rsync-repo.sh --name alpine --host rsync.alpinelinux.org --path alpine/ --reload --sync
EOF
