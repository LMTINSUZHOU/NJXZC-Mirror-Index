#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${MIRROR_ENV_FILE:-/etc/njxzu-mirrors.env}"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

NAME=""
RSYNC_HOST=""
RSYNC_PATH=""
CRON="17 */4 * * *"
STORAGE_DIR=""
CONFIG_DIR="${YUKI_CONFIG_DIR:-/etc/yuki/repos}"
WEB_ROOT="${MIRROR_WEB_ROOT:-/srv/mirror/www}"
OWNER_USER="${MIRROR_USER:-mirror}"
OWNER_GROUP="${MIRROR_GROUP:-mirror}"
IMAGE="ustcmirror/rsync:latest"
LOG_ROT_CYCLE="5"
RETRY="1"
MAX_DELETE="50000"
BW_LIMIT="0"
EXCLUDE="--exclude=.~tmp~/"
EXTRA=""
FILTER=""
RSYNC_USER=""
RSYNC_RSH=""
UPSTREAM=""
NO_DELETE="false"
SSL="false"
DO_RELOAD=0
DO_SYNC=0

usage() {
  cat <<EOF
Usage: sudo $0 --name NAME --host RSYNC_HOST --path RSYNC_PATH [options]

Create a yuki repository config that syncs through ustcmirror/rsync.

Required:
  --name NAME             Local repo name, also the URL path by default.
  --host HOST             Rsync host, e.g. rsync.alpinelinux.org.
  --path PATH             Rsync module/path, e.g. alpine/.

Options:
  --cron EXPR             5-field cron. Default: "$CRON"
  --storage-dir PATH      Local storage dir. Default: \$MIRROR_WEB_ROOT/NAME
  --config-dir PATH       Yuki repo config dir. Default: $CONFIG_DIR
  --image IMAGE           Sync image. Default: $IMAGE
  --max-delete N          Rsync --max-delete. Default: $MAX_DELETE
  --bwlimit KBPS          Rsync bandwidth limit. Default: $BW_LIMIT
  --exclude VALUE         RSYNC_EXCLUDE. Default: $EXCLUDE
  --extra VALUE           Extra rsync args, e.g. "--size-only"
  --filter VALUE          RSYNC_FILTER content.
  --rsync-user USER       Rsync user.
  --rsync-rsh VALUE       SSH remote shell, e.g. "ssh -i /home/mirror/.ssh/id_rsa"
  --upstream URL          Display upstream. Default: rsync://HOST/PATH
  --no-delete             Set RSYNC_NO_DELETE=true.
  --ssl                   Set RSYNC_SSL=true.
  --reload                Run "yukictl reload" after writing config.
  --sync                  Run "yukictl sync NAME" after reload.
  --help                  Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    --host) RSYNC_HOST="$2"; shift 2 ;;
    --path) RSYNC_PATH="$2"; shift 2 ;;
    --cron) CRON="$2"; shift 2 ;;
    --storage-dir) STORAGE_DIR="$2"; shift 2 ;;
    --config-dir) CONFIG_DIR="$2"; shift 2 ;;
    --image) IMAGE="$2"; shift 2 ;;
    --max-delete) MAX_DELETE="$2"; shift 2 ;;
    --bwlimit) BW_LIMIT="$2"; shift 2 ;;
    --exclude) EXCLUDE="$2"; shift 2 ;;
    --extra) EXTRA="$2"; shift 2 ;;
    --filter) FILTER="$2"; shift 2 ;;
    --rsync-user) RSYNC_USER="$2"; shift 2 ;;
    --rsync-rsh) RSYNC_RSH="$2"; shift 2 ;;
    --upstream) UPSTREAM="$2"; shift 2 ;;
    --no-delete) NO_DELETE="true"; shift ;;
    --ssl) SSL="true"; shift ;;
    --reload) DO_RELOAD=1; shift ;;
    --sync) DO_SYNC=1; DO_RELOAD=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$NAME" || -z "$RSYNC_HOST" || -z "$RSYNC_PATH" ]]; then
  usage >&2
  exit 2
fi

if [[ "$NAME" == *"/"* || "$NAME" == "."* || "$NAME" == *".."* ]]; then
  echo "Invalid repo name: $NAME" >&2
  exit 2
fi

STORAGE_DIR="${STORAGE_DIR:-$WEB_ROOT/$NAME}"
UPSTREAM="${UPSTREAM:-rsync://$RSYNC_HOST/$RSYNC_PATH}"
CONFIG_FILE="$CONFIG_DIR/$NAME.yaml"

yaml_quote() {
  local value="$1"
  value="$(printf '%s' "$value" | sed "s/'/''/g")"
  printf "'%s'" "$value"
}

if [[ "${EUID}" -eq 0 ]]; then
  install -d -o "$OWNER_USER" -g "$OWNER_GROUP" "$STORAGE_DIR"
  install -d -m 0755 "$CONFIG_DIR"
else
  mkdir -p "$STORAGE_DIR" "$CONFIG_DIR"
fi

tmp="$(mktemp)"
{
  printf 'name: %s\n' "$(yaml_quote "$NAME")"
  printf 'cron: %s\n' "$(yaml_quote "$CRON")"
  printf 'storageDir: %s\n' "$(yaml_quote "$STORAGE_DIR")"
  printf 'image: %s\n' "$(yaml_quote "$IMAGE")"
  printf 'logRotCycle: %s\n' "$LOG_ROT_CYCLE"
  printf 'retry: %s\n' "$RETRY"
  printf 'envs:\n'
  printf '  RSYNC_HOST: %s\n' "$(yaml_quote "$RSYNC_HOST")"
  printf '  RSYNC_PATH: %s\n' "$(yaml_quote "$RSYNC_PATH")"
  printf '  RSYNC_MAXDELETE: %s\n' "$(yaml_quote "$MAX_DELETE")"
  printf '  RSYNC_BW: %s\n' "$(yaml_quote "$BW_LIMIT")"
  printf '  RSYNC_EXCLUDE: %s\n' "$(yaml_quote "$EXCLUDE")"
  printf '  RSYNC_NO_DELETE: %s\n' "$(yaml_quote "$NO_DELETE")"
  printf '  RSYNC_SSL: %s\n' "$(yaml_quote "$SSL")"
  printf '  $UPSTREAM: %s\n' "$(yaml_quote "$UPSTREAM")"
  [[ -n "$EXTRA" ]] && printf '  RSYNC_EXTRA: %s\n' "$(yaml_quote "$EXTRA")"
  [[ -n "$FILTER" ]] && printf '  RSYNC_FILTER: %s\n' "$(yaml_quote "$FILTER")"
  [[ -n "$RSYNC_USER" ]] && printf '  RSYNC_USER: %s\n' "$(yaml_quote "$RSYNC_USER")"
  [[ -n "$RSYNC_RSH" ]] && printf '  RSYNC_RSH: %s\n' "$(yaml_quote "$RSYNC_RSH")"
} > "$tmp"

install -m 0644 "$tmp" "$CONFIG_FILE"
rm -f "$tmp"

echo "Wrote $CONFIG_FILE"
echo "Storage directory: $STORAGE_DIR"

if [[ "$DO_RELOAD" == "1" ]]; then
  yukictl reload
fi

if [[ "$DO_SYNC" == "1" ]]; then
  yukictl sync "$NAME"
fi
