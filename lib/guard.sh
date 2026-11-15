#!/bin/bash
# The auto-mode scheduler. Runs as root every 2 minutes from pearl-auto.timer.
#   inside a mining window AND the GPU is free  -> miner on
#   outside the windows, or the GPU is in use   -> miner off
# Set PEARLMINE_DRY_RUN=1 to print the decision without starting or stopping anything.
set -uo pipefail
DIR="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
# shellcheck disable=SC1091
source "$DIR/lib/common.sh"
load_conf "${PEARLMINE_CONF:-$DIR/pearlmine.conf}" || exit 1
DRY=${PEARLMINE_DRY_RUN:-0}
log() { echo "pearlmine: $*"; }      # journald picks this up

mins() { local t=$1; [[ $t == *:* ]] || t="$t:00"; echo $(( 10#${t%%:*} * 60 + 10#${t##*:} )); }
in_window() {  # now-minutes, start HH:MM, end HH:MM; handles windows that cross midnight
  local n=$1 s e; s=$(mins "$2"); e=$(mins "$3")
  if (( s == e )); then return 1; fi
  if (( s > e )); then (( n >= s || n < e )); else (( n >= s && n < e )); fi
}

NOW=$(mins "${PEARLMINE_NOW:-$(date +%H:%M)}")
DOW=${PEARLMINE_DOW:-$(date +%u)}        # 1=Mon ... 7=Sun
IN=0; WHY=""
if in_window "$NOW" "${NIGHT_START:-22:00}" "${NIGHT_END:-06:00}"; then IN=1; WHY="night window"; fi
if (( ${DAY_WINDOW:-0} )) && [[ " ${DAY_WINDOW_DAYS:-1 2 3 4 5} " == *" $DOW "* ]] \
   && in_window "$NOW" "${DAY_START:-09:00}" "${DAY_END:-17:00}"; then
  IN=1; WHY="day window"
fi

# Other programs computing on the managed GPUs (the miner itself and anything in IGNORE_GPU_PROCS excluded).
OTHERS=""
if (( ${PAUSE_WHEN_GPU_BUSY:-1} )); then
  if [ -n "${PEARLMINE_OTHERS+x}" ]; then
    RAW=$PEARLMINE_OTHERS                                  # test hook
  else
    mapfile -t LIST < <(gpu_list)
    RAW=""
    if [ ${#LIST[@]} -gt 0 ]; then
      ids=$(IFS=,; echo "${LIST[*]}")
      RAW=$(nvidia-smi -i "$ids" --query-compute-apps=process_name --format=csv,noheader 2>/dev/null || true)
    fi
  fi
  SKIP='wildrig-multi'
  [ -n "${IGNORE_GPU_PROCS:-}" ] && SKIP="$SKIP|$IGNORE_GPU_PROCS"
  OTHERS=$(grep -vE "$SKIP" <<<"$RAW" | grep -v '^[[:space:]]*$' || true)
fi

if [ -n "${PEARLMINE_RUNNING+x}" ]; then RUNNING=$PEARLMINE_RUNNING
else RUNNING=$(systemctl is-active pearl-miner.service 2>/dev/null || true); fi

act() { if (( DRY )); then log "(dry run) would run: systemctl $*"; else systemctl "$@"; fi; }

if (( IN )) && [ -z "$OTHERS" ]; then
  if [ "$RUNNING" = active ]; then (( DRY )) && log "$WHY, GPU free -> keep mining"
  else log "$WHY, GPU free -> starting miner"; act start pearl-miner.service; fi
else
  if (( IN )); then REASON="GPU in use by: $(tr '\n' ' ' <<<"$OTHERS")"; else REASON="outside mining windows"; fi
  if [ "$RUNNING" = active ]; then log "$REASON -> stopping miner"; act stop pearl-miner.service pearl-gpu-tune.service
  else (( DRY )) && log "$REASON -> stay off"; fi
fi
exit 0
