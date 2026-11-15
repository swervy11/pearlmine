#!/bin/bash
# Optional GPU tuning while mining (NVIDIA only). Runs as root from pearl-gpu-tune.service.
#   apply : apply whatever is set in pearlmine.conf (power cap, clock locks); remembers the old power limit
#   reset : undo it
#   show  : print current limits and clocks, change nothing
# Every setting is optional. With nothing set this does nothing at all.
set -uo pipefail
DIR="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
# shellcheck disable=SC1091
source "$DIR/lib/common.sh"
load_conf "$DIR/pearlmine.conf" || exit 1
STATE=/run/pearlmine
q() { nvidia-smi -i "$1" --query-gpu="$2" --format=csv,noheader,nounits | cut -d. -f1 | tr -d ' '; }
isnum() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

mapfile -t LIST < <(gpu_list)
if [ ${#LIST[@]} -eq 0 ]; then echo "pearlmine: no NVIDIA GPU found, tuning skipped"; exit 0; fi

case "${1:-apply}" in
  apply)
    mkdir -p "$STATE"
    for g in "${LIST[@]}"; do
      if isnum "${POWER_LIMIT_W:-}"; then
        lo=$(q "$g" power.min_limit); hi=$(q "$g" power.max_limit)
        if isnum "$lo" && isnum "$hi" && { (( POWER_LIMIT_W < lo )) || (( POWER_LIMIT_W > hi )); }; then
          echo "pearlmine: GPU $g allows ${lo}-${hi} W; POWER_LIMIT_W=$POWER_LIMIT_W is outside that. Not starting." >&2; exit 1
        fi
        q "$g" power.limit > "$STATE/powerlimit.$g"
        nvidia-smi -i "$g" -pm 1 >/dev/null
        nvidia-smi -i "$g" -pl "$POWER_LIMIT_W" >/dev/null || { echo "pearlmine: GPU $g power cap failed" >&2; exit 1; }
      fi
      if isnum "${CORE_CLOCK_MHZ:-}"; then
        nvidia-smi -i "$g" -lgc "$CORE_CLOCK_MHZ,$CORE_CLOCK_MHZ" >/dev/null && touch "$STATE/core.$g" \
          || echo "pearlmine: GPU $g core clock lock not applied (unsupported on this card or driver)" >&2
      fi
      if isnum "${MEM_CLOCK_MHZ:-}"; then
        nvidia-smi -i "$g" -lmc "$MEM_CLOCK_MHZ,$MEM_CLOCK_MHZ" >/dev/null && touch "$STATE/mem.$g" \
          || echo "pearlmine: GPU $g memory clock lock not applied (unsupported on this card or driver)" >&2
      fi
    done
    ;;
  reset)
    for g in "${LIST[@]}"; do
      [ -e "$STATE/core.$g" ] && { nvidia-smi -i "$g" -rgc >/dev/null || true; rm -f "$STATE/core.$g"; }
      [ -e "$STATE/mem.$g" ]  && { nvidia-smi -i "$g" -rmc >/dev/null || true; rm -f "$STATE/mem.$g"; }
      if [ -s "$STATE/powerlimit.$g" ]; then
        nvidia-smi -i "$g" -pl "$(cat "$STATE/powerlimit.$g")" >/dev/null || true
        rm -f "$STATE/powerlimit.$g"
      fi
    done
    ;;
  show) ;;
  *) echo "usage: $0 apply|reset|show" >&2; exit 2 ;;
esac
ids=$(IFS=,; echo "${LIST[*]}")
nvidia-smi -i "$ids" --query-gpu=index,name,power.limit,clocks.gr,clocks.mem,temperature.gpu --format=csv
