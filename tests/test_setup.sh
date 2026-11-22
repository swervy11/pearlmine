#!/bin/bash
# Tests the first-run address prompt in `pearlmine setup` (Linux). Runs in a temporary copy of the
# repo with a stub miner, so nothing is downloaded and no unit or GPU is touched.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cp -r "$REPO/pearlmine" "$REPO/pearlmine.conf.example" "$REPO/lib" "$T/"
mkdir -p "$T/miner/9.9.9" && printf '#!/bin/sh\n' > "$T/miner/9.9.9/wildrig-multi" && chmod +x "$T/miner/9.9.9/wildrig-multi"
ln -s 9.9.9 "$T/miner/current"
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL  $1  got '$2' want '$3'"; fi; }
val() { sed -n "s/^$1=//p" "$T/pearlmine.conf" | head -1; }

ADDR="prl1p$(printf 'q%.0s' $(seq 58))"
SEED="abandon ability able about above absent absorb abstract absurd abuse access accident"
UPPER=$(tr '[:lower:]' '[:upper:]' <<<"$ADDR")

out=$(printf '%s\n%s\n%s\n%s\n' "$SEED" "prl1pshort" "$UPPER" "gaming-rig" | PEARLMINE_PROMPT_STDIN=1 "$T/pearlmine" setup 2>&1); rc=$?
check "setup exit" "$rc" 0
check "address saved (lowercased)" "$(val PRL_WALLET)" "$ADDR"
check "worker saved" "$(val PRL_WORKER)" "gaming-rig"
check "seed warning" "$(grep -c 'looks like seed words' <<<"$out")" 1
check "bad address explained" "$(grep -c 'that was 10' <<<"$out")" 1
check "seed never echoed" "$(grep -cE 'abandon|absurd' <<<"$out")" 0
check "seed never saved" "$(grep -cE 'abandon|absurd' "$T/pearlmine.conf")" 0
check "wallet link shown" "$(grep -c 'pearl-research-labs/pearl/releases' <<<"$out")" 1
check "ready message" "$(grep -c 'Ready. Start with' <<<"$out")" 1
check "conf still private" "$(stat -c %a "$T/pearlmine.conf")" 600
check "only one PRL_WALLET line" "$(grep -c '^PRL_WALLET=' "$T/pearlmine.conf")" 1

out=$(PEARLMINE_PROMPT_STDIN=1 "$T/pearlmine" setup </dev/null 2>&1)
check "no prompt once set" "$(grep -c 'needs your Pearl wallet' <<<"$out")" 0

rm "$T/pearlmine.conf"
out=$(printf '\n' | PEARLMINE_PROMPT_STDIN=1 "$T/pearlmine" setup 2>&1); rc=$?
check "skip exit" "$rc" 0
check "skip message" "$(grep -c 'Skipped' <<<"$out")" 1
check "skip leaves address empty" "$(val PRL_WALLET)" ""

rm "$T/pearlmine.conf"
out=$("$T/pearlmine" setup </dev/null 2>&1)
check "no prompt without a terminal" "$(grep -c 'needs your Pearl wallet' <<<"$out")" 0

echo "setup: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
