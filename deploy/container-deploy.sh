#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${MIRROR_CONTAINER_ENV_FILE:-/etc/njxzu-mirrors-container.env}"
YUKI_ENV_FILE="${MIRROR_ENV_FILE:-/etc/njxzu-mirrors.env}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run as root: sudo $0" >&2
  exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
  install -m 0644 "$SCRIPT_DIR/container.env.example" "$ENV_FILE"
  echo "Created $ENV_FILE. Continuing with defaults; edit it later if needed."
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

MIRROR_ROOT="${MIRROR_ROOT:-/srv/mirror}"
MIRROR_WEB_ROOT="${MIRROR_WEB_ROOT:-/srv/mirror/www}"
MIRROR_SRC_DIR="${MIRROR_SRC_DIR:-/opt/njxzu-mirrors-index}"
MIRROR_USER="${MIRROR_USER:-mirror}"
MIRROR_GROUP="${MIRROR_GROUP:-mirror}"
INSTALL_PACKAGES="${INSTALL_PACKAGES:-1}"

if [[ "$INSTALL_PACKAGES" == "1" ]] && command -v apt-get >/dev/null 2>&1; then
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates curl docker.io docker-compose-plugin git rsync
fi

if ! getent group "$MIRROR_GROUP" >/dev/null; then
  groupadd --system "$MIRROR_GROUP"
fi

if ! id "$MIRROR_USER" >/dev/null 2>&1; then
  useradd --system --home-dir "$MIRROR_ROOT" --shell /usr/sbin/nologin \
    --gid "$MIRROR_GROUP" "$MIRROR_USER"
fi

if getent group docker >/dev/null; then
  usermod -aG docker "$MIRROR_USER"
fi

install -d -o "$MIRROR_USER" -g "$MIRROR_GROUP" "$MIRROR_ROOT" "$MIRROR_WEB_ROOT"
touch "$MIRROR_ROOT/.sync-trigger"
chown "$MIRROR_USER:$MIRROR_GROUP" "$MIRROR_ROOT/.sync-trigger"

if [[ -d "$SRC_ROOT/.git" ]]; then
  git -C "$SRC_ROOT" submodule update --init --recursive
fi

if [[ ! -f "$SRC_ROOT/z-genisolist/genisolist.py" ]]; then
  echo "z-genisolist is missing. Run: git submodule update --init --recursive" >&2
  exit 1
fi

if [[ "$SRC_ROOT" != "$MIRROR_SRC_DIR" ]]; then
  install -d "$MIRROR_SRC_DIR"
  rsync -a --delete \
    --exclude ".git/" \
    --exclude "__pycache__/" \
    --exclude ".pytest_cache/" \
    "$SRC_ROOT/" "$MIRROR_SRC_DIR/"
fi

chmod +x "$MIRROR_SRC_DIR"/scripts/*.sh "$MIRROR_SRC_DIR"/deploy/*.sh
chown -R root:root "$MIRROR_SRC_DIR"
chown -R "$MIRROR_USER:$MIRROR_GROUP" "$MIRROR_WEB_ROOT"

if [[ ! -f "$YUKI_ENV_FILE" ]]; then
  install -m 0644 "$MIRROR_SRC_DIR/deploy/mirror.env.example" "$YUKI_ENV_FILE"
fi

ensure_env_line() {
  local key="$1"
  local value="$2"
  if grep -q "^${key}=" "$YUKI_ENV_FILE"; then
    sed -i.bak "s#^${key}=.*#${key}=${value}#" "$YUKI_ENV_FILE"
  else
    printf '%s=%s\n' "$key" "$value" >> "$YUKI_ENV_FILE"
  fi
}

ensure_env_line "MIRROR_DEPLOY_MODE" "container"
ensure_env_line "MIRROR_SRC_DIR" "$MIRROR_SRC_DIR"
ensure_env_line "MIRROR_ROOT" "$MIRROR_ROOT"
ensure_env_line "MIRROR_CONTAINER_COMPOSE_FILE" "$MIRROR_SRC_DIR/deploy/compose.yaml"
ensure_env_line "MIRROR_CONTAINER_COMPOSE_ENV" "$ENV_FILE"
ensure_env_line "MIRROR_WEB_ROOT" "$MIRROR_WEB_ROOT"
ensure_env_line "MIRROR_HTTPDIR" "$MIRROR_WEB_ROOT"
ensure_env_line "MIRROR_OUTDIR" "$MIRROR_WEB_ROOT"
if ! grep -q '^MIRROR_YUKI_URL=' "$YUKI_ENV_FILE"; then
  printf 'MIRROR_YUKI_URL=http://127.0.0.1:9999/api/v1/metas\n' >> "$YUKI_ENV_FILE"
fi

systemctl enable --now docker

docker compose --env-file "$ENV_FILE" -f "$MIRROR_SRC_DIR/deploy/compose.yaml" up -d --build

cat <<EOF
Containerized NX OpenAtom web/index services are running.

Compose file: $MIRROR_SRC_DIR/deploy/compose.yaml
Compose env:  $ENV_FILE
Web root:     $MIRROR_WEB_ROOT

yuki remains on the host. If it is not installed yet:
  sudo $MIRROR_SRC_DIR/deploy/setup-yuki.sh
EOF
