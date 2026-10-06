#!/usr/bin/env bash
# Opt-in pod diagnostics (PERF_EVAL_PODSTAT=1). Source this from run.sh.
#
#   podstat_snapshot <tag>   one-off dump of the pod's environment and limits
#   podstat_start            background sampler of CPU throttling / memory
#   podstat_stop             stop the sampler
#
# Everything is read-only and goes to stdout with a "[podstat]" prefix, so it
# lands in the Buildkite log next to the vLLM server log it explains.

PODSTAT_INTERVAL="${PERF_EVAL_PODSTAT_INTERVAL:-5}"
_podstat_cg=/sys/fs/cgroup

_podstat_cat() {
  local f
  for f in "$@"; do
    [[ -r "$f" ]] || continue
    sed "s|^|[podstat] ${f##*/}: |" "$f"
  done
}

podstat_snapshot() {
  [[ "${PERF_EVAL_PODSTAT:-}" == 1 ]] || return 0
  local tag=${1:-snapshot}
  echo "--- :mag: podstat ${tag}"
  {
    echo "[podstat] date: $(date -Is)  host: $(hostname)  kernel: $(uname -r)"
    echo "[podstat] amdgpu: $(cat /sys/module/amdgpu/version 2>/dev/null || echo n/a)"
    echo "[podstat] nproc: $(nproc)  online: $(cat /sys/devices/system/cpu/online 2>/dev/null)"
    echo "[podstat] cgroup: $(cat /proc/self/cgroup 2>/dev/null | tr '\n' ' ')"
    _podstat_cat "$_podstat_cg"/cpu.max "$_podstat_cg"/cpu.weight "$_podstat_cg"/cpu.stat \
                 "$_podstat_cg"/cpuset.cpus.effective "$_podstat_cg"/cpuset.mems.effective \
                 "$_podstat_cg"/memory.max "$_podstat_cg"/memory.high "$_podstat_cg"/memory.current \
                 "$_podstat_cg"/memory.events "$_podstat_cg"/memory.pressure "$_podstat_cg"/cpu.pressure
    grep -E "^(anon|file|shmem|file_dirty|file_writeback|pgmajfault|workingset_refault_file) " \
      "$_podstat_cg"/memory.stat 2>/dev/null | sed 's/^/[podstat] memory.stat: /'
    df -h /dev/shm /tmp /workspace "${HF_HOME:-/nonexistent}" 2>/dev/null | sed 's/^/[podstat] df: /'
    command -v numactl >/dev/null && numactl -H 2>/dev/null | head -4 | sed 's/^/[podstat] numa: /'
    lscpu 2>/dev/null | grep -E "^(Model name|Socket|NUMA node\(s\)|CPU max MHz|CPU min MHz)" | sed 's/^/[podstat] lscpu: /'
    grep -m1 "cpu MHz" /proc/cpuinfo | sed 's/^/[podstat] /'
    # Environment, with anything credential-shaped redacted.
    env | sort | sed -E 's/^([^=]*(TOKEN|SECRET|KEY|PASSWORD|AUTH)[^=]*)=.*/\1=<redacted>/' \
        | sed 's/^/[podstat] env: /'
    local smi
    smi=$(command -v rocm-smi || ls /opt/rocm/bin/rocm-smi 2>/dev/null)
    [[ -n "$smi" ]] && "$smi" --showuse --showpower --showclocks --showmaxpower \
        --showcomputepartition --showmemorypartition --showfwinfo 2>/dev/null \
        | grep -vE "^=+|^$" | sed 's/^/[podstat] rocm-smi: /'
  } || true
}

podstat_start() {
  [[ "${PERF_EVAL_PODSTAT:-}" == 1 ]] || return 0
  (
    while :; do
      printf '[podstat] sample %s cpu.stat{%s} mem.current=%s mem.events{%s} cpu.pressure{%s}\n' \
        "$(date +%T)" \
        "$( { tr '\n' ' ' < "$_podstat_cg"/cpu.stat; } 2>/dev/null)" \
        "$(cat "$_podstat_cg"/memory.current 2>/dev/null)" \
        "$( { tr '\n' ' ' < "$_podstat_cg"/memory.events; } 2>/dev/null)" \
        "$(head -1 "$_podstat_cg"/cpu.pressure 2>/dev/null)"
      sleep "$PODSTAT_INTERVAL"
    done
  ) &
  PODSTAT_PID=$!
}

podstat_stop() {
  [[ -n "${PODSTAT_PID:-}" ]] && kill "$PODSTAT_PID" 2>/dev/null || true
}
