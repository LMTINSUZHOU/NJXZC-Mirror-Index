#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${MIRROR_ENV_FILE:-/etc/njxzu-mirrors.env}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run as root: sudo $0" >&2
  exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
  install -m 0644 "$SCRIPT_DIR/mirror.env.example" "$ENV_FILE"
  echo "Created $ENV_FILE. Continuing with defaults; edit it later if your domain or paths differ."
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
MIRROR_DOMAIN="${MIRROR_DOMAIN:-mirrors.njxzu.cn}"
YUKI_LISTEN="${YUKI_LISTEN:-127.0.0.1:9999}"
INSTALL_PACKAGES="${INSTALL_PACKAGES:-1}"

if [[ "$INSTALL_PACKAGES" == "1" ]] && command -v apt-get >/dev/null 2>&1; then
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    git nginx rsync python3 python3-jinja2 python3-requests
fi

if ! getent group "$MIRROR_GROUP" >/dev/null; then
  groupadd --system "$MIRROR_GROUP"
fi

if ! id "$MIRROR_USER" >/dev/null 2>&1; then
  useradd --system --home-dir "$MIRROR_ROOT" --shell /usr/sbin/nologin \
    --gid "$MIRROR_GROUP" "$MIRROR_USER"
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

unit_tmp="$(mktemp)"
sed \
  -e "s#User=mirror#User=$MIRROR_USER#g" \
  -e "s#Group=mirror#Group=$MIRROR_GROUP#g" \
  -e "s#/opt/njxzu-mirrors-index#$MIRROR_SRC_DIR#g" \
  "$MIRROR_SRC_DIR/services/mirrors-index.service" > "$unit_tmp"
install -m 0644 "$unit_tmp" /etc/systemd/system/mirrors-index.service
rm -f "$unit_tmp"
install -m 0644 "$MIRROR_SRC_DIR/services/mirrors-index.timer" /etc/systemd/system/mirrors-index.timer
install -m 0644 "$MIRROR_SRC_DIR/services/mirrors-index.path" /etc/systemd/system/mirrors-index.path

nginx_tmp="$(mktemp)"
sed \
  -e "s#__MIRROR_DOMAIN__#$MIRROR_DOMAIN#g" \
  -e "s#__MIRROR_WEB_ROOT__#$MIRROR_WEB_ROOT#g" \
  -e "s#__YUKI_LISTEN__#$YUKI_LISTEN#g" \
  "$MIRROR_SRC_DIR/deploy/nginx.njxzu-mirrors.conf" > "$nginx_tmp"
if [[ -d /etc/nginx/sites-available ]]; then
  install -m 0644 "$nginx_tmp" /etc/nginx/sites-available/njxzu-mirrors.conf
  ln -sfn /etc/nginx/sites-available/njxzu-mirrors.conf /etc/nginx/sites-enabled/njxzu-mirrors.conf
else
  install -m 0644 "$nginx_tmp" /etc/nginx/conf.d/njxzu-mirrors.conf
fi
rm -f "$nginx_tmp"

MIRROR_ENV_FILE="$ENV_FILE" "$MIRROR_SRC_DIR/scripts/generate-index.sh"
chown -R "$MIRROR_USER:$MIRROR_GROUP" "$MIRROR_WEB_ROOT"

systemctl daemon-reload
systemctl enable --now mirrors-index.timer
systemctl enable --now mirrors-index.path

if command -v nginx >/dev/null 2>&1; then
  nginx -t
  systemctl enable --now nginx
  systemctl reload nginx
fi

cat <<EOF
NX OpenAtom index is installed.

Web root:   $MIRROR_WEB_ROOT
Source:     $MIRROR_SRC_DIR
Env file:   $ENV_FILE
Nginx host: http://$MIRROR_DOMAIN/

Optional next step:
  sudo $MIRROR_SRC_DIR/deploy/setup-yuki.sh
EOF
