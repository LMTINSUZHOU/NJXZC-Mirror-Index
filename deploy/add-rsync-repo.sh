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
CRON="17 3 * * *"
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
  --host HOST             Rsync host, e.g. rsync.mirrors.ustc.edu.cn.
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

is_ustc_host() {
  [[ "$RSYNC_HOST" == "rsync.mirrors.ustc.edu.cn" || "$RSYNC_HOST" == *".ustc.edu.cn" ]]
}

is_ustc_hot_repo() {
  [[ "$NAME" == ubuntu* || "$RSYNC_PATH" == ubuntu* ]]
}

reject_checksum_extra() {
  [[ "$EXTRA" =~ (^|[[:space:]])--checksum($|[[:space:]]) ]] && return 0
  [[ "$EXTRA" =~ (^|[[:space:]])-[A-Za-z]*c[A-Za-z]*($|[[:space:]]) ]] && return 0
  return 1
}

validate_ustc_hot_hour_list() {
  local raw="$1"
  local IFS=','
  local values=($raw)
  local sorted prev first current gap
  local -a normalized=()

  if (( ${#values[@]} == 0 || ${#values[@]} > 4 )); then
    return 1
  fi

  for current in "${values[@]}"; do
    [[ "$current" =~ ^[0-9]+$ ]] || return 1
    (( current >= 0 && current <= 23 )) || return 1
    normalized+=("$current")
  done

  sorted="$(printf '%s\n' "${normalized[@]}" | sort -n | uniq)"
  normalized=()
  while IFS= read -r current; do
    [[ -n "$current" ]] && normalized+=("$current")
  done <<< "$sorted"

  if (( ${#normalized[@]} != ${#values[@]} )); then
    return 1
  fi

  first="${normalized[0]}"
  prev="$first"
  for ((i = 1; i < ${#normalized[@]}; i++)); do
    current="${normalized[i]}"
    gap=$(( current - prev ))
    (( gap >= 6 )) || return 1
    prev="$current"
  done

  gap=$(( 24 + first - prev ))
  (( gap >= 6 )) || return 1
  return 0
}

validate_ustc_cron() {
  local minute hour dom month dow
  read -r minute hour dom month dow <<< "$CRON"

  if [[ -z "${dow:-}" ]]; then
    echo "Invalid cron expression: $CRON" >&2
    exit 2
  fi

  if [[ ! "$minute" =~ ^[0-9]+$ ]]; then
    echo "Use a fixed minute for USTC sync jobs; got: $CRON" >&2
    exit 2
  fi

  if [[ "$hour" =~ ^[0-9]+$ ]]; then
    return
  fi

  if is_ustc_hot_repo; then
    if [[ "$hour" =~ ^\*/([0-9]+)$ ]]; then
      local step="${BASH_REMATCH[1]}"
      if (( step >= 6 )); then
        return
      fi
    fi

    if validate_ustc_hot_hour_list "$hour"; then
      return
    fi

    echo "USTC allows ubuntu-like hot repos at most once every 6 hours; use a cron like '37 */6 * * *'." >&2
    exit 2
  fi

  echo "USTC recommends non-ubuntu repos sync no more than once per day; use a cron like '17 3 * * *'." >&2
  exit 2
}

if [[ "$RSYNC_HOST" == "mirrors.ustc.edu.cn" ]]; then
  echo "Use USTC rsync-only host: rsync.mirrors.ustc.edu.cn" >&2
  exit 2
fi

if is_ustc_host; then
  if [[ "$RSYNC_HOST" != "rsync.mirrors.ustc.edu.cn" ]]; then
    echo "Use USTC rsync-only host: rsync.mirrors.ustc.edu.cn" >&2
    exit 2
  fi
  validate_ustc_cron
fi

if reject_checksum_extra; then
  echo "Do not use -c/--checksum with rsync; USTC explicitly forbids checksum mode for mirror sync." >&2
  exit 2
fi

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
