#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DOMAIN="${MIRROR_DOMAIN:-mirrors.njxzu.cn}"
EMAIL="${MIRROR_CONTACT_EMAIL:-mirror@openatom.njxzu.cn}"
ISSUE_URL="${MIRROR_ISSUE_URL:-mailto:mirror@openatom.njxzu.cn?subject=Mirror%20issue}"
WEB_ROOT="${MIRROR_WEB_ROOT:-/srv/mirror/www}"
SRC_DIR="${MIRROR_SRC_DIR:-/opt/njxzu-mirrors-index}"
CONTAINER_ENV="${MIRROR_CONTAINER_ENV_FILE:-/etc/njxzu-mirrors-container.env}"
YUKI_ENV="${MIRROR_ENV_FILE:-/etc/njxzu-mirrors.env}"
INSTALL_WEB=1
INSTALL_YUKI=1

usage() {
  cat <<EOF
Usage: sudo $0 [options]

Install NX OpenAtom with web/index in containers and yuki on the host.

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

random_hex() {
  local bytes="$1"
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex "$bytes"
  else
    od -An -N "$bytes" -tx1 /dev/urandom | tr -d ' \n'
  fi
}

ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-$(random_hex 12)}"
ADMIN_SECRET_KEY="${ADMIN_SECRET_KEY:-$(random_hex 32)}"

write_env_file() {
  local path="$1"
  shift
  install -d "$(dirname "$path")"
  [[ -f "$path" ]] || : > "$path"
  while [[ $# -gt 0 ]]; do
    local key="$1"
    local value="$2"
    local quoted
    quoted="$(printf '%s' "$value" | sed "s/'/'\\\\''/g")"
    if grep -q "^${key}=" "$path"; then
      sed -i "s#^${key}=.*#${key}='${quoted}'#" "$path"
    else
      printf "%s='%s'\n" "$key" "$quoted" >> "$path"
    fi
    shift 2
  done
}

ensure_admin_secrets() {
  local path="$1"
  install -d "$(dirname "$path")"
  [[ -f "$path" ]] || : > "$path"
  local pw secret
  pw="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 18)"
  secret="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 48)"
  set_or_replace_env() {
    local key="$1" value="$2" quoted
    quoted="$(printf '%s' "$value" | sed "s/'/'\\''/g")"
    if grep -q "^${key}=" "$path"; then
      sed -i "s#^${key}=.*#${key}='${quoted}'#" "$path"
    else
      printf "%s='%s'\n" "$key" "$quoted" >> "$path"
    fi
  }
  : "${ADMIN_USERNAME:=admin}"
  : "${ADMIN_PORT:=8088}"
  set_or_replace_env "ADMIN_USERNAME" "$ADMIN_USERNAME"
  : "${ADMIN_PASSWORD:=$pw}"
  : "${ADMIN_SECRET_KEY:=$secret}"
  set_or_replace_env "ADMIN_PASSWORD" "$ADMIN_PASSWORD"
  set_or_replace_env "ADMIN_SECRET_KEY" "$ADMIN_SECRET_KEY"
  set_or_replace_env "ADMIN_PORT" "$ADMIN_PORT"
}

write_env_file "$CONTAINER_ENV" \
  MIRROR_NAME "NX OpenAtom" \
  MIRROR_SITE_TITLE "南晓开放原子社开源软件镜像站" \
  MIRROR_BRAND "NX OpenAtom" \
  MIRROR_HERO_TITLE "NX OpenAtom" \
  MIRROR_HERO_SUBTITLE "南晓开放原子社开源软件镜像站" \
  MIRROR_HERO_DESCRIPTION "为校内外用户提供常用开源软件、Linux 发行版与开发工具镜像服务。" \
  MIRROR_ORGANIZATION "南晓开放原子社" \
  MIRROR_SUPPORT "南晓开放原子社" \
  MIRROR_DOMAIN "$DOMAIN" \
  MIRROR_BASE_URL "https://$DOMAIN" \
  MIRROR_LOGO_URL "/static/img/nx-openatom-logo.jpg" \
  MIRROR_CONTACT_EMAIL "$EMAIL" \
  MIRROR_WEB_ROOT "$WEB_ROOT" \
  MIRROR_HELP_URL "https://help.mirrors.cernet.edu.cn/" \
  MIRROR_STATUS_URL "/status/" \
  MIRROR_STATUS_JSON_URL "/status/json" \
  MIRROR_ABOUT_URL "https://www.njxzc.edu.cn/" \
  MIRROR_NEWS_URL "" \
  MIRROR_NEWS_FEED "" \
  MIRROR_REQUEST_URL "mailto:$EMAIL?subject=New%20mirror%20request" \
  MIRROR_ISSUE_URL "$ISSUE_URL" \
  YUKI_PROXY_URL "http://127.0.0.1:9999" \
  MIRROR_YUKI_URL "http://127.0.0.1:9999/api/v1/metas" \
  MIRROR_INDEX_INTERVAL "600" \
  MIRROR_CONTAINER_ENV_FILE "$CONTAINER_ENV" \
  ADMIN_BIND "127.0.0.1:18081" \
  ADMIN_PROXY_URL "http://127.0.0.1:18081" \
  ADMIN_WORKERS "2" \
  ADMIN_USERNAME "$ADMIN_USERNAME" \
  ADMIN_PASSWORD "$ADMIN_PASSWORD" \
  ADMIN_SECRET_KEY "$ADMIN_SECRET_KEY" \
  ADMIN_PORT "${ADMIN_PORT:-18081}" \
  ADMIN_ALLOW_CIDRS "127.0.0.1/32,::1/128,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10" \
  ADMIN_REPO_DIR "/etc/yuki/repos" \
  ADMIN_REPO_DISABLED_DIR "/etc/yuki/repos.disabled" \
  ADMIN_EXAMPLE_REPO_DIR "/app/deploy/yuki/repos" \
  ADMIN_YUKICTL_BIN "/usr/local/bin/yukictl" \
  ADMIN_YUKI_URL "http://127.0.0.1:9999/api/v1/metas" \
  ADMIN_GENERATE_INDEX_SCRIPT "/app/scripts/generate-index.sh" \
  ADMIN_GENERATE_TIMEOUT "300"

ensure_admin_secrets "$CONTAINER_ENV"

write_env_file "$YUKI_ENV" \
  MIRROR_NAME "NX OpenAtom" \
  MIRROR_SITE_TITLE "南晓开放原子社开源软件镜像站" \
  MIRROR_BRAND "NX OpenAtom" \
  MIRROR_HERO_TITLE "NX OpenAtom" \
  MIRROR_HERO_SUBTITLE "南晓开放原子社开源软件镜像站" \
  MIRROR_HERO_DESCRIPTION "为校内外用户提供常用开源软件、Linux 发行版与开发工具镜像服务。" \
  MIRROR_ORGANIZATION "南晓开放原子社" \
  MIRROR_SUPPORT "南晓开放原子社" \
  MIRROR_DOMAIN "$DOMAIN" \
  MIRROR_BASE_URL "https://$DOMAIN" \
  MIRROR_LOGO_URL "/static/img/nx-openatom-logo.jpg" \
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
  MIRROR_ISSUE_URL "$ISSUE_URL" \
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
Admin URL:     http://$DOMAIN/admin/
Admin user:    $ADMIN_USERNAME
Admin pass:    $ADMIN_PASSWORD

Add an rsync repository:
  sudo $SRC_DIR/deploy/add-rsync-repo.sh --name ubuntu-releases --host rsync.mirrors.ustc.edu.cn --path ubuntu-releases/ --cron "37 */6 * * *" --reload
EOF
