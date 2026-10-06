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
# cgroup v1 (or hybrid) hosts expose one directory per controller instead.
_podstat_v1cpu=$(ls -d /sys/fs/cgroup/cpu,cpuacct /sys/fs/cgroup/cpu 2>/dev/null | head -1)
_podstat_v1mem=/sys/fs/cgroup/memory
_podstat_v1set=/sys/fs/cgroup/cpuset

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
    # cgroup v1
    _podstat_cat "$_podstat_v1cpu"/cpu.cfs_quota_us "$_podstat_v1cpu"/cpu.cfs_period_us \
                 "$_podstat_v1cpu"/cpu.shares "$_podstat_v1cpu"/cpu.stat \
                 "$_podstat_v1set"/cpuset.cpus "$_podstat_v1set"/cpuset.mems \
                 "$_podstat_v1mem"/memory.limit_in_bytes "$_podstat_v1mem"/memory.soft_limit_in_bytes \
                 "$_podstat_v1mem"/memory.usage_in_bytes "$_podstat_v1mem"/memory.max_usage_in_bytes \
                 "$_podstat_v1mem"/memory.failcnt "$_podstat_v1mem"/memory.oom_control
    grep -E "^(total_)?(cache|rss|shmem|mapped_file|dirty|writeback|pgmajfault|inactive_file|active_file) " \
      "$_podstat_v1mem"/memory.stat 2>/dev/null | sed 's/^/[podstat] v1 memory.stat: /'
    # Node-wide pressure (cgroup v1 has no per-cgroup PSI).
    for _p in cpu memory io; do
      [[ -r /proc/pressure/$_p ]] && sed "s|^|[podstat] node pressure $_p: |" /proc/pressure/$_p
    done
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
      printf '[podstat] sample %s cpu.stat{%s} mem.current=%s mem.events{%s} cpu.pressure{%s} v1cpu{%s} v1mem{usage=%s max=%s failcnt=%s %s} node.psi{cpu:%s mem:%s}\n' \
        "$(date +%T)" \
        "$( { tr '\n' ' ' < "$_podstat_cg"/cpu.stat; } 2>/dev/null)" \
        "$(cat "$_podstat_cg"/memory.current 2>/dev/null)" \
        "$( { tr '\n' ' ' < "$_podstat_cg"/memory.events; } 2>/dev/null)" \
        "$(head -1 "$_podstat_cg"/cpu.pressure 2>/dev/null)" \
        "$( { tr '\n' ' ' < "$_podstat_v1cpu"/cpu.stat; } 2>/dev/null)" \
        "$(cat "$_podstat_v1mem"/memory.usage_in_bytes 2>/dev/null)" \
        "$(cat "$_podstat_v1mem"/memory.max_usage_in_bytes 2>/dev/null)" \
        "$(cat "$_podstat_v1mem"/memory.failcnt 2>/dev/null)" \
        "$(grep -E '^(total_)?(cache|rss|shmem|pgmajfault) ' "$_podstat_v1mem"/memory.stat 2>/dev/null | tr '\n' ' ')" \
        "$(head -1 /proc/pressure/cpu 2>/dev/null)" \
        "$(head -1 /proc/pressure/memory 2>/dev/null)"
      sleep "$PODSTAT_INTERVAL"
    done
  ) &
  PODSTAT_PID=$!
}

podstat_stop() {
  [[ -n "${PODSTAT_PID:-}" ]] && kill "$PODSTAT_PID" 2>/dev/null || true
  [[ -n "${PODSTAT_HANG_PID:-}" ]] && kill "$PODSTAT_HANG_PID" 2>/dev/null || true
}

# Hang capture: if the server is not healthy PERF_EVAL_PODSTAT_HANG_AFTER seconds
# after start, dump lock holders, Python stacks, process tree and GPU state, twice.
PODSTAT_HANG_AFTER="${PERF_EVAL_PODSTAT_HANG_AFTER:-1800}"

podstat_install_pyspy() {
  [[ "${PERF_EVAL_PODSTAT:-}" == 1 ]] || return 0
  command -v py-spy >/dev/null && return 0
  ( python3 -m pip install --quiet py-spy >/dev/null 2>&1 \
      || python3 -m pip install --user --quiet py-spy >/dev/null 2>&1 ) || true
  echo "[podstat] py-spy: $(command -v py-spy || echo unavailable)"
}

_podstat_lock_report() {
  # AITER's FileBaton is an O_CREAT|O_EXCL file whose contents are "<pid>\n<host>\n";
  # waiters poll for it to disappear and only break it if the holder is dead.
  local f pid host age
  ls -la --time-style=+%T /tmp/aiter_configs 2>/dev/null | sed 's/^/[podstat] aiter_configs: /'
  for f in /tmp/aiter_configs/*.lock /root/.aiter/build/*/lock; do
    [[ -e "$f" ]] || continue
    pid=$(sed -n 1p "$f" 2>/dev/null); host=$(sed -n 2p "$f" 2>/dev/null)
    age=$(( $(date +%s) - $(stat -c %Y "$f" 2>/dev/null || date +%s) ))
    echo "[podstat] lock $f holder_pid=${pid:-<empty>} host=${host:-?} age=${age}s alive=$([[ -n "$pid" && -d /proc/$pid ]] && echo yes || echo no)"
    if [[ -n "$pid" && -r /proc/$pid/status ]]; then
      echo "[podstat]   holder: $(tr '\0' ' ' < /proc/$pid/cmdline 2>/dev/null | cut -c1-120) | $(grep -E '^State' /proc/$pid/status | tr -s '\t ' ' ') | wchan=$(cat /proc/$pid/wchan 2>/dev/null)"
    fi
  done
}

podstat_hang_capture() {
  local tag=$1 p
  echo "--- :rotating_light: podstat hang capture ${tag}"
  {
    echo "[podstat] hang ${tag} at $(date -Is)"
    _podstat_lock_report
    echo "[podstat] process tree:"
    ps -eo pid,ppid,stat,pcpu,rss,etimes,wchan:32,args --forest 2>/dev/null | cut -c1-260 | sed 's/^/[podstat] ps: /'
    echo "[podstat] threads not sleeping (R/D):"
    ps -eLo pid,tid,stat,pcpu,wchan:32,comm 2>/dev/null | awk 'NR==1 || $3 ~ /^[RD]/' | sed 's/^/[podstat] thr: /'
    for p in $(pgrep -f -- 'vllm|VLLM|python' 2>/dev/null); do
      [[ -r /proc/$p/status ]] || continue
      echo "[podstat] === pid $p $(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | cut -c1-160)"
      grep -E '^(State|Threads|VmRSS)' /proc/$p/status 2>/dev/null | sed 's/^/[podstat]   /'
      echo "[podstat]   wchan: $(cat /proc/$p/wchan 2>/dev/null)"
      sed 's/^/[podstat]   kstack: /' /proc/$p/stack 2>/dev/null | head -12
      if command -v py-spy >/dev/null; then
        # Native frames name the HIP/HSA call a rank is stuck in; fall back to
        # Python-only frames if native unwinding is unavailable.
        { timeout 90 py-spy dump --native --pid "$p" 2>&1 || timeout 60 py-spy dump --pid "$p" 2>&1; } \
          | head -140 | sed 's/^/[podstat]   py: /'
      fi
    done
    local smi; smi=$(command -v rocm-smi || ls /opt/rocm/bin/rocm-smi 2>/dev/null)
    [[ -n "$smi" ]] && "$smi" --showuse --showpower --showmemuse 2>/dev/null | grep -E "GPU use|Power \(|VRAM%" | sed 's/^/[podstat] rocm-smi: /'
  } || true
}

podstat_hangwatch() {
  [[ "${PERF_EVAL_PODSTAT:-}" == 1 ]] || return 0
  local port=$1
  (
    local start=$SECONDS
    while :; do
      sleep 60
      curl -sf -m 5 "http://127.0.0.1:${port}/health" >/dev/null 2>&1 && exit 0
      if (( SECONDS - start >= PODSTAT_HANG_AFTER )); then
        podstat_hang_capture first
        sleep 120
        curl -sf -m 5 "http://127.0.0.1:${port}/health" >/dev/null 2>&1 && exit 0
        podstat_hang_capture second
        exit 0
      fi
    done
  ) &
  PODSTAT_HANG_PID=$!
}

# Node facts for sizing pod requests: host memory, CPUs, and (if the service
# account may read it) the node's allocatable capacity from the k8s API.
podstat_node_probe() {
  [[ "${PERF_EVAL_PODSTAT:-}" == 1 ]] || return 0
  echo "--- :mag: podstat node probe"
  {
    grep -E "^(MemTotal|MemAvailable|HugePages_Total|Hugepagesize):" /proc/meminfo | sed 's/^/[podstat] meminfo: /'
    echo "[podstat] cpus: online=$(cat /sys/devices/system/cpu/online) nproc=$(nproc) cpuset=$(cat /sys/fs/cgroup/cpuset/cpuset.cpus 2>/dev/null || cat /sys/fs/cgroup/cpuset.cpus.effective 2>/dev/null)"
    echo "[podstat] k8s node: ${BUILDKITE_AGENT_META_DATA_K8S_NODE:-unknown}"
    local sa=/var/run/secrets/kubernetes.io/serviceaccount node=${BUILDKITE_AGENT_META_DATA_K8S_NODE:-}
    if [[ -r $sa/token && -n "$node" ]]; then
      curl -s -m 20 --cacert $sa/ca.crt -H "Authorization: Bearer $(cat $sa/token)" \
        "https://kubernetes.default.svc/api/v1/nodes/$node" \
        | python3 -c 'import json,sys
d=json.load(sys.stdin)
if d.get("kind")!="Node": print("[podstat] k8s api:", d.get("reason"), d.get("message","")[:160]); raise SystemExit
st=d["status"]
for k in ("capacity","allocatable"): print("[podstat] k8s", k, {r: st[k].get(r) for r in ("cpu","memory","amd.com/gpu","ephemeral-storage","hugepages-2Mi","hugepages-1Gi","pods")})
print("[podstat] k8s taints:", d["spec"].get("taints")); print("[podstat] k8s labels:", {k:v for k,v in d["metadata"].get("labels",{}).items() if "node" in k or "pool" in k or "gpu" in k or "instance" in k})' 2>&1
      curl -s -m 20 --cacert $sa/ca.crt -H "Authorization: Bearer $(cat $sa/token)" \
        "https://kubernetes.default.svc/api/v1/namespaces/$(cat $sa/namespace)/limitranges" \
        | python3 -c 'import json,sys
d=json.load(sys.stdin)
print("[podstat] limitranges:", json.dumps([i.get("spec") for i in d.get("items",[])]) if "items" in d else (d.get("reason"), d.get("message","")[:160]))' 2>&1
    else
      echo "[podstat] k8s api: no service-account token mounted"
    fi
  } || true
}
