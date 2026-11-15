# shellcheck shell=bash
# Shared by the root-run helpers (gpu-tune.sh, guard.sh). Sourced, not executed.

load_conf() {
  local conf=$1
  [ -f "$conf" ] || { echo "pearlmine: $conf not found" >&2; return 1; }
  # These helpers run as root and source the config, so it must not be writable by other users.
  if [ -n "$(find "$conf" -perm /022 2>/dev/null)" ]; then
    echo "pearlmine: $conf is writable by group or others; run: chmod 600 $conf" >&2; return 1
  fi
  # shellcheck disable=SC1090
  source "$conf"
}

# Echo the NVIDIA GPU indexes to manage, one per line. Empty if there is no NVIDIA driver.
gpu_list() {
  command -v nvidia-smi >/dev/null || return 0
  if [ "${GPUS:-all}" = all ]; then
    nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null
  else
    tr -s ' ,' '\n' <<<"$GPUS" | grep -E '^[0-9]+$' || true
  fi
}
