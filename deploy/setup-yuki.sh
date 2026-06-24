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
fi

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

MIRROR_ROOT="${MIRROR_ROOT:-/srv/mirror}"
MIRROR_WEB_ROOT="${MIRROR_WEB_ROOT:-/srv/mirror/www}"
MIRROR_SRC_DIR="${MIRROR_SRC_DIR:-/opt/njxzu-mirrors-index}"
MIRROR_USER="${MIRROR_USER:-mirror}"
MIRROR_GROUP="${MIRROR_GROUP:-mirror}"
YUKI_LISTEN="${YUKI_LISTEN:-127.0.0.1:9999}"
YUKI_CONFIG_DIR="${YUKI_CONFIG_DIR:-/etc/yuki/repos}"
YUKI_LOG_DIR="${YUKI_LOG_DIR:-/var/log/yuki}"
YUKI_DB="${YUKI_DB:-/var/lib/yuki/yukid.db}"
INSTALL_PACKAGES="${INSTALL_PACKAGES:-1}"

if [[ "$INSTALL_PACKAGES" == "1" ]] && command -v apt-get >/dev/null 2>&1; then
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates curl docker.io sqlite3
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

case "$(uname -m)" in
  x86_64|amd64) yuki_arch="amd64" ;;
  aarch64|arm64) yuki_arch="arm64" ;;
  *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

curl -fL "https://github.com/ustclug/Yuki/releases/latest/download/yukid_linux_${yuki_arch}" \
  -o /usr/local/bin/yukid
curl -fL "https://github.com/ustclug/Yuki/releases/latest/download/yukictl_linux_${yuki_arch}" \
  -o /usr/local/bin/yukictl
chmod 0755 /usr/local/bin/yukid /usr/local/bin/yukictl

install -d -o "$MIRROR_USER" -g "$MIRROR_GROUP" "$MIRROR_WEB_ROOT"
install -d -o "$MIRROR_USER" -g "$MIRROR_GROUP" "$(dirname "$YUKI_DB")" "$YUKI_LOG_DIR"
install -d -m 0755 /etc/yuki "$YUKI_CONFIG_DIR"

uid_gid="$(id -u "$MIRROR_USER"):$(getent group "$MIRROR_GROUP" | cut -d: -f3)"
daemon_tmp="$(mktemp)"
cat > "$daemon_tmp" <<EOF
db_url = "$YUKI_DB"
repo_config_dir = ["$YUKI_CONFIG_DIR"]
repo_logs_dir = "$YUKI_LOG_DIR"
fs = "default"
owner = "$uid_gid"
listen_addr = "$YUKI_LISTEN"
log_level = "info"
sync_timeout = "48h"
images_upgrade_interval = "6h"
post_sync = ["$MIRROR_SRC_DIR/scripts/post-sync-regenerate.sh"]
EOF
install -m 0644 "$daemon_tmp" /etc/yuki/daemon.toml
rm -f "$daemon_tmp"

if [[ -f "$ENV_FILE" ]] && ! grep -q '^MIRROR_YUKI_URL=' "$ENV_FILE"; then
  printf '\nMIRROR_YUKI_URL=http://%s/api/v1/metas\n' "$YUKI_LISTEN" >> "$ENV_FILE"
fi

if [[ -d "$SRC_ROOT/deploy/yuki/repos" ]]; then
  rsync -a --ignore-existing "$SRC_ROOT/deploy/yuki/repos/" "$YUKI_CONFIG_DIR/"
fi

service_src="$SRC_ROOT/deploy/yukid.service"
if [[ -f "$MIRROR_SRC_DIR/deploy/yukid.service" ]]; then
  service_src="$MIRROR_SRC_DIR/deploy/yukid.service"
fi
service_tmp="$(mktemp)"
sed \
  -e "s#User=mirror#User=$MIRROR_USER#g" \
  -e "s#Group=mirror#Group=$MIRROR_GROUP#g" \
  "$service_src" > "$service_tmp"
install -m 0644 "$service_tmp" /etc/systemd/system/yukid.service
rm -f "$service_tmp"

systemctl daemon-reload
systemctl enable --now docker
systemctl enable --now yukid.service

cat <<EOF
Yuki is installed.

Daemon config: /etc/yuki/daemon.toml
Repo configs:  $YUKI_CONFIG_DIR
Status JSON:   http://$YUKI_LISTEN/api/v1/metas

Enable a sample repo:
  sudo cp $YUKI_CONFIG_DIR/ubuntu-releases.yaml.example $YUKI_CONFIG_DIR/ubuntu-releases.yaml
  sudo install -d -o $MIRROR_USER -g $MIRROR_GROUP $MIRROR_WEB_ROOT/ubuntu-releases
  sudo yukictl reload
  sudo yukictl sync ubuntu-releases
EOF
