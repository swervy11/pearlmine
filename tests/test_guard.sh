#!/bin/bash
# Checks the auto-mode decision for fixed times, days and GPU states. Starts and stops nothing.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0

conf() { printf '%s\n' "$@" > "$TMP/conf"; chmod 600 "$TMP/conf"; }
# run <now> <dow> <running> <others> ; prints the guard's decision line
run() {
  PEARLMINE_CONF="$TMP/conf" PEARLMINE_DRY_RUN=1 PEARLMINE_NOW=$1 PEARLMINE_DOW=$2 \
    PEARLMINE_RUNNING=$3 PEARLMINE_OTHERS=$4 "$ROOT/lib/guard.sh" 2>&1 | head -1
}
expect() {  # name, expected substring, actual
  if [[ "$3" == *"$2"* ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; echo "   wanted: $2"; echo "   got:    $3"; fi
}

BASE=(NIGHT_START=22:00 NIGHT_END=06:00 DAY_WINDOW=0 PAUSE_WHEN_GPU_BUSY=1 'IGNORE_GPU_PROCS=""')
conf "${BASE[@]}"
expect "night, free, stopped -> start"        "starting miner"          "$(run 23:30 3 inactive '')"
expect "after midnight still in window"       "starting miner"          "$(run 02:00 3 inactive '')"
expect "window start is inclusive"            "starting miner"          "$(run 22:00 3 inactive '')"
expect "window end is exclusive"              "outside mining windows"  "$(run 06:00 3 active '')"
expect "daytime, running -> stop"             "stopping miner"          "$(run 12:00 3 active '')"
expect "daytime, stopped -> stay off"         "stay off"                "$(run 12:00 3 inactive '')"
expect "night, already running -> keep"       "keep mining"             "$(run 23:30 3 active '')"
expect "night, GPU busy, running -> stop"     "GPU in use by: python3"  "$(run 23:30 3 active 'python3')"
expect "night, GPU busy, stopped -> stay off" "stay off"                "$(run 23:30 3 inactive 'python3')"
expect "the miner itself is not 'busy'"       "keep mining"             "$(run 23:30 3 active '/opt/x/wildrig-multi')"

conf "${BASE[@]:0:4}" 'IGNORE_GPU_PROCS="ollama|bg-svc"'
expect "ignored process does not pause"       "keep mining"             "$(run 23:30 3 active 'ollama')"
expect "non-ignored process still pauses"     "GPU in use by: blender"  "$(run 23:30 3 active $'ollama\nblender')"

conf NIGHT_START=22:00 NIGHT_END=06:00 DAY_WINDOW=0 PAUSE_WHEN_GPU_BUSY=0
expect "busy check off -> mine anyway"        "keep mining"             "$(run 23:30 3 active 'python3')"

conf NIGHT_START=22:00 NIGHT_END=06:00 DAY_WINDOW=1 'DAY_WINDOW_DAYS="1 2 3 4 5"' DAY_START=09:00 DAY_END=17:00
expect "day window on a weekday"              "day window"              "$(run 12:00 2 inactive '')"
expect "day window off at the weekend"        "outside mining windows"  "$(run 12:00 6 active '')"
expect "between the windows on a weekday"     "outside mining windows"  "$(run 07:30 2 active '')"

conf NIGHT_START=01:00 NIGHT_END=05:00 DAY_WINDOW=0
expect "same-day window, inside"              "starting miner"          "$(run 03:00 1 inactive '')"
expect "same-day window, outside"             "stay off"                "$(run 23:00 1 inactive '')"

conf NIGHT_START=00:00 NIGHT_END=00:00 DAY_WINDOW=0
expect "start equals end means never"         "stay off"                "$(run 03:00 1 inactive '')"

conf "${BASE[@]}"; chmod 666 "$TMP/conf"
expect "world-writable config is refused"     "writable by group or others" "$(run 23:30 3 inactive '')"

echo "guard: $pass passed, $fail failed"
(( fail == 0 ))
