#!/bin/bash
# Starts the miner as your normal user. Called by pearl-miner.service.
set -euo pipefail
DIR="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
# shellcheck disable=SC1091
source "$DIR/pearlmine.conf"
[[ "${PRL_WALLET:-}" =~ ^prl1p[0-9a-z]{58}$ ]] || { echo "PRL_WALLET is not a 63-character prl1p address" >&2; exit 2; }
BIN="$DIR/miner/current/wildrig-multi"
[ -x "$BIN" ] || { echo "miner not installed (run: pearlmine setup)" >&2; exit 2; }

mkdir -p "$DIR/logs"
LOG="$DIR/logs/miner.log"
# keep one old log once the current one passes 20 MB
if [ -f "$LOG" ] && [ "$(stat -c %s "$LOG")" -gt 20000000 ]; then mv -f "$LOG" "$LOG.1"; fi

# MINER_EXTRA_ARGS is split on spaces on purpose so several flags can be passed.
# shellcheck disable=SC2086
exec "$BIN" \
  --algo pearlhash \
  --url "${PRL_POOL:-pool.pearlhash.xyz:9000}" \
  --user "$PRL_WALLET" \
  --worker "${PRL_WORKER:-rig1}" \
  --print-time 60 \
  --gpu-temp-limit "${TEMP_LIMIT:-82}" \
  --gpu-temp-resume "${TEMP_RESUME:-65}" \
  --log-file "$LOG" \
  ${MINER_EXTRA_ARGS:-}
