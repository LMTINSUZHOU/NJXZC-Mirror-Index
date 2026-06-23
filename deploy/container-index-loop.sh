#!/usr/bin/env bash
set -euo pipefail

INTERVAL="${MIRROR_INDEX_INTERVAL:-600}"

stop_requested=0
trap 'stop_requested=1' INT TERM

run_once() {
  date '+[%F %T] generating mirrors index'
  /app/scripts/generate-index.sh
}

run_once

while [[ "$stop_requested" -eq 0 ]]; do
  sleep "$INTERVAL" &
  wait "$!" || true
  [[ "$stop_requested" -eq 1 ]] && break
  run_once
done
