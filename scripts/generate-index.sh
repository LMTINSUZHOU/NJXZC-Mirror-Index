#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${MIRROR_ENV_FILE:-/etc/njxzu-mirrors.env}"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

MIRROR_WEB_ROOT="${MIRROR_WEB_ROOT:-${MIRROR_OUTDIR:-/srv/mirror/www}}"
MIRROR_HTTPDIR="${MIRROR_HTTPDIR:-$MIRROR_WEB_ROOT}"
MIRROR_OUTDIR="${MIRROR_OUTDIR:-$MIRROR_WEB_ROOT}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

mkdir -p "$MIRROR_WEB_ROOT/static" "$MIRROR_WEB_ROOT/status"
rsync -a --delete "$ROOT_DIR/static/" "$MIRROR_WEB_ROOT/static/"
rsync -a --delete "$ROOT_DIR/status/" "$MIRROR_WEB_ROOT/status/"

export MIRROR_HTTPDIR MIRROR_OUTDIR
"$PYTHON_BIN" "$ROOT_DIR/genindex.py" \
  --outdir "$MIRROR_OUTDIR" \
  --output "$MIRROR_OUTDIR/index.html" \
  --mirrorz "$MIRROR_OUTDIR/mirrorz.json" \
  "$@"
