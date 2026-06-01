#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  pius-llm-bench.bash [options]

Run an OpenAI-compatible llama-server benchmark and write a self-contained run
directory with request timings plus system, cgroup, CPU, PSI, IRQ, and optional
hidden cache-allocation MSR state.

Typical remote use from the repo:
  ssh pius 'bash -s -- --modes none,house1 --repeats 4 --label real-load' \
    < tools/pius-llm-bench.bash

Options:
  --endpoint URL          OpenAI-compatible endpoint base URL
                          default: http://127.0.0.1:8012
  --model NAME           model name; default: first /v1/models id
  --prompt TEXT          prompt to send
  --prompt-set NAME      prompt source: single or mixed; default: single
  --max-tokens N         generated tokens per request; default: 128
  --repeats N            repetitions per mode; default: 3
  --modes CSV            modes to interleave; default: none
                          supported tokens: none, house1, irq, perf, maxperf,
                          sched:NAME
                          combine tokens with +, e.g. irq+perf, house1+irq
                          sched:NAME applies a block scheduler before a sample;
                          samples without sched: restore the saved schedulers
  --sequence CSV         explicit per-sample mode order; overrides --repeats
  --housekeeping-cpus S  CPUs for system/noise/cache-restricted work; default: 0-1
  --irq-cpu-mask HEX     hex CPU mask for default IRQ affinity; default: derived
                          from --housekeeping-cpus
  --workload-cpus S      CPUs for LLM work; default: 2-5
  --block-devices CSV    block devices for sched: modes and per-sample storage
                          capture; default: nvme0n1
  --storage-paths CSV    paths whose backing mounts are captured; default:
                          output directory plus IO-noise directory when used
  --noise none|cache|io  optional controlled housekeeping noise; default: none
  --noise-duration SEC   stress-ng timeout when --noise is enabled; default: 900
  --cache-size SIZE      stress-ng cache size; default: 9M
  --io-workers N         stress-ng hdd workers for --noise io; default: 2
  --io-bytes SIZE        bytes per hdd worker for --noise io; default: 1G
  --io-opts CSV          stress-ng hdd options for --noise io;
                          default: wr-rnd,rd-rnd,fsync
  --io-temp-path DIR     parent directory for --noise io temp files; default:
                          the run output directory
  --noise-io-weight N    systemd IOWeight for the noise unit; unset by default
  --out-root DIR         output root; default: /persist/models/bench/harness
  --label NAME           run directory prefix; default: pius-llm
  --services CSV         systemd units to sample counters from
  --seed N               base seed; default: 42000
  -h, --help             show this help
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require() {
  local missing=()
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  ((${#missing[@]} == 0)) || die "missing required command(s): ${missing[*]}"
}

mode_has() {
  local mode="$1"
  local wanted="$2"
  local token
  local -a tokens
  IFS='+' read -ra tokens <<< "$mode"
  for token in "${tokens[@]}"; do
    [[ "$token" == "$wanted" ]] && return 0
  done
  return 1
}

mode_scheduler() {
  local mode="$1"
  local token
  local -a tokens
  IFS='+' read -ra tokens <<< "$mode"
  for token in "${tokens[@]}"; do
    if [[ "$token" == sched:* ]]; then
      printf '%s' "${token#sched:}"
      return 0
    fi
  done
  return 1
}

validate_mode() {
  local mode="$1"
  local scheduler scheduler_count=0 token
  local -a tokens
  [[ -n "$mode" ]] || die "empty mode"
  IFS='+' read -ra tokens <<< "$mode"
  for token in "${tokens[@]}"; do
    case "$token" in
      none|house1|irq|perf|maxperf) ;;
      sched:*)
        scheduler="${token#sched:}"
        [[ -n "$scheduler" ]] || die "empty scheduler token in mode: $mode"
        [[ "$scheduler" =~ ^[A-Za-z0-9._-]+$ ]] || die "unsafe scheduler '$scheduler' in mode: $mode"
        scheduler_count=$((scheduler_count + 1))
        ;;
      *) die "unsupported mode token '$token' in mode: $mode" ;;
    esac
  done
  ((scheduler_count <= 1)) || die "multiple sched: tokens in mode: $mode"
  if mode_has "$mode" none && ((${#tokens[@]} > 1)); then
    die "'none' cannot be combined with other mode tokens: $mode"
  fi
}

endpoint=http://127.0.0.1:8012
model=
prompt='Write exactly 128 lowercase a letters and nothing else.'
prompt_set=single
max_tokens=128
repeats=3
modes_csv=none
sequence_csv=
housekeeping_cpus=0-1
irq_cpu_mask=
workload_cpus=2-5
block_devices_csv=nvme0n1
storage_paths_csv=
noise=none
noise_duration=900
cache_size=9M
io_workers=2
io_bytes=1G
io_opts=wr-rnd,rd-rnd,fsync
io_temp_path=
noise_io_weight=
out_root=/persist/models/bench/harness
label=pius-llm
services_csv=reddit-mirror-pius-20260501.service,transmission.service,tailscaled.service,samba-smbd.service,llama-cpp.service
seed_base=42000

while (($# > 0)); do
  case "$1" in
    --endpoint) endpoint="$2"; shift 2 ;;
    --endpoint=*) endpoint="${1#*=}"; shift ;;
    --model) model="$2"; shift 2 ;;
    --model=*) model="${1#*=}"; shift ;;
    --prompt) prompt="$2"; shift 2 ;;
    --prompt=*) prompt="${1#*=}"; shift ;;
    --prompt-set) prompt_set="$2"; shift 2 ;;
    --prompt-set=*) prompt_set="${1#*=}"; shift ;;
    --max-tokens) max_tokens="$2"; shift 2 ;;
    --max-tokens=*) max_tokens="${1#*=}"; shift ;;
    --repeats) repeats="$2"; shift 2 ;;
    --repeats=*) repeats="${1#*=}"; shift ;;
    --modes) modes_csv="$2"; shift 2 ;;
    --modes=*) modes_csv="${1#*=}"; shift ;;
    --sequence) sequence_csv="$2"; shift 2 ;;
    --sequence=*) sequence_csv="${1#*=}"; shift ;;
    --housekeeping-cpus) housekeeping_cpus="$2"; shift 2 ;;
    --housekeeping-cpus=*) housekeeping_cpus="${1#*=}"; shift ;;
    --irq-cpu-mask) irq_cpu_mask="$2"; shift 2 ;;
    --irq-cpu-mask=*) irq_cpu_mask="${1#*=}"; shift ;;
    --workload-cpus) workload_cpus="$2"; shift 2 ;;
    --workload-cpus=*) workload_cpus="${1#*=}"; shift ;;
    --block-devices) block_devices_csv="$2"; shift 2 ;;
    --block-devices=*) block_devices_csv="${1#*=}"; shift ;;
    --storage-paths) storage_paths_csv="$2"; shift 2 ;;
    --storage-paths=*) storage_paths_csv="${1#*=}"; shift ;;
    --noise) noise="$2"; shift 2 ;;
    --noise=*) noise="${1#*=}"; shift ;;
    --noise-duration) noise_duration="$2"; shift 2 ;;
    --noise-duration=*) noise_duration="${1#*=}"; shift ;;
    --cache-size) cache_size="$2"; shift 2 ;;
    --cache-size=*) cache_size="${1#*=}"; shift ;;
    --io-workers) io_workers="$2"; shift 2 ;;
    --io-workers=*) io_workers="${1#*=}"; shift ;;
    --io-bytes) io_bytes="$2"; shift 2 ;;
    --io-bytes=*) io_bytes="${1#*=}"; shift ;;
    --io-opts) io_opts="$2"; shift 2 ;;
    --io-opts=*) io_opts="${1#*=}"; shift ;;
    --io-temp-path) io_temp_path="$2"; shift 2 ;;
    --io-temp-path=*) io_temp_path="${1#*=}"; shift ;;
    --noise-io-weight) noise_io_weight="$2"; shift 2 ;;
    --noise-io-weight=*) noise_io_weight="${1#*=}"; shift ;;
    --out-root) out_root="$2"; shift 2 ;;
    --out-root=*) out_root="${1#*=}"; shift ;;
    --label) label="$2"; shift 2 ;;
    --label=*) label="${1#*=}"; shift ;;
    --services) services_csv="$2"; shift 2 ;;
    --services=*) services_csv="${1#*=}"; shift ;;
    --seed) seed_base="$2"; shift 2 ;;
    --seed=*) seed_base="${1#*=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ "$repeats" =~ ^[0-9]+$ ]] || die "--repeats must be an integer"
[[ "$max_tokens" =~ ^[0-9]+$ ]] || die "--max-tokens must be an integer"
[[ "$seed_base" =~ ^[0-9]+$ ]] || die "--seed must be an integer"
[[ "$io_workers" =~ ^[0-9]+$ ]] || die "--io-workers must be an integer"
[[ -z "$noise_io_weight" || "$noise_io_weight" =~ ^[0-9]+$ ]] || die "--noise-io-weight must be an integer"
((repeats > 0)) || die "--repeats must be positive"
((max_tokens > 0)) || die "--max-tokens must be positive"
((io_workers > 0)) || die "--io-workers must be positive"
if [[ -n "$noise_io_weight" ]]; then
  ((noise_io_weight >= 1 && noise_io_weight <= 10000)) || die "--noise-io-weight must be between 1 and 10000"
fi

IFS=',' read -ra configured_modes <<< "$modes_csv"
if [[ -n "$sequence_csv" ]]; then
  IFS=',' read -ra schedule <<< "$sequence_csv"
else
  schedule=("${configured_modes[@]}")
fi
IFS=',' read -ra services <<< "$services_csv"
IFS=',' read -ra block_devices <<< "$block_devices_csv"
((${#configured_modes[@]} > 0)) || die "--modes must not be empty"
((${#schedule[@]} > 0)) || die "--sequence must not be empty when set"
((${#block_devices[@]} > 0)) || die "--block-devices must not be empty"

needs_msr=0
needs_irq=0
needs_power=0
needs_block_scheduler=0
for mode in "${schedule[@]}"; do
  validate_mode "$mode"
  mode_has "$mode" house1 && needs_msr=1
  mode_has "$mode" irq && needs_irq=1
  if mode_scheduler "$mode" >/dev/null; then
    needs_block_scheduler=1
  fi
  if mode_has "$mode" perf || mode_has "$mode" maxperf; then
    needs_power=1
  fi
done

case "$noise" in
  none) ;;
  cache) ;;
  io) ;;
  *) die "unsupported noise mode: $noise" ;;
esac

case "$prompt_set" in
  single|mixed) ;;
  *) die "unsupported prompt set: $prompt_set" ;;
esac

require curl jq date mkdir sed tr awk head sort
if ((needs_msr)); then
  require rdmsr wrmsr
fi
if [[ "$noise" != none ]]; then
  require stress-ng taskset systemd-run systemctl
fi
if ((needs_block_scheduler)); then
  require grep
fi

if [[ -z "$model" ]]; then
  model=$(curl -fsS "$endpoint/v1/models" | jq -r '.data[0].id // empty')
  [[ -n "$model" ]] || die "could not infer model from $endpoint/v1/models"
fi

stamp=$(date -u +%Y%m%dT%H%M%SZ)
out="$out_root/$label-$stamp"
mkdir -p "$out/responses" "$out/samples"

noise_unit="llm-bench-$noise-noise-$stamp.service"
if [[ -n "$io_temp_path" ]]; then
  io_noise_dir="$io_temp_path/llm-bench-io-$stamp"
else
  io_noise_dir="$out/noise-io"
fi
if [[ -n "$storage_paths_csv" ]]; then
  IFS=',' read -ra storage_paths <<< "$storage_paths_csv"
else
  storage_paths=("$out")
  if [[ "$noise" == io ]]; then
    storage_paths+=("$io_noise_dir")
  fi
fi
cpus_for_msr="$housekeeping_cpus,$workload_cpus"
msrs=(0xc90 0xc91 0xc92 0xc93)
mixed_prompts=(
  'In about 180 words, explain why CPU cache locality matters for local LLM inference. Keep the answer practical and concrete.'
  'In about 180 words, describe a careful Linux benchmarking workflow for CPU pinning, IRQ placement, and cache noise.'
  'In about 180 words, compare latency, jitter, and throughput when tuning a home server for local LLM inference.'
  'In about 180 words, outline the risks and measurement safeguards for experiments with undocumented cache-allocation MSRs.'
)

expand_cpu_list() {
  local spec="$1"
  local part start end cpu
  IFS=',' read -ra ranges <<< "$spec"
  for part in "${ranges[@]}"; do
    if [[ "$part" == *-* ]]; then
      start="${part%-*}"
      end="${part#*-}"
      for ((cpu = start; cpu <= end; cpu++)); do
        printf '%s\n' "$cpu"
      done
    elif [[ -n "$part" ]]; then
      printf '%s\n' "$part"
    fi
  done
}

cpu_list_to_hexmask() {
  local spec="$1"
  local cpu mask=0
  for cpu in $(expand_cpu_list "$spec"); do
    [[ "$cpu" =~ ^[0-9]+$ ]] || die "invalid CPU in list '$spec': $cpu"
    ((cpu < 63)) || die "cannot derive IRQ mask for CPU >= 63: $cpu"
    ((mask |= 1 << cpu))
  done
  printf '%x' "$mask"
}

if [[ -z "$irq_cpu_mask" ]]; then
  irq_cpu_mask=$(cpu_list_to_hexmask "$housekeeping_cpus")
fi

hex() {
  case "$1" in
    0x*) printf '%s' "$1" ;;
    *) printf '0x%s' "$1" ;;
  esac
}

pqr_state() {
  local cpu
  if ! command -v rdmsr >/dev/null 2>&1; then
    printf 'unavailable'
    return
  fi
  for cpu in $(expand_cpu_list "$cpus_for_msr"); do
    printf '%s:%s ' "$cpu" "$(rdmsr -p "$cpu" 0xc8f 2>/dev/null || printf err)"
  done
}

mask_state() {
  local msr
  if ! command -v rdmsr >/dev/null 2>&1; then
    printf 'unavailable'
    return
  fi
  for msr in "${msrs[@]}"; do
    printf '%s:%s ' "$msr" "$(rdmsr -p 0 "$msr" 2>/dev/null || printf err)"
  done
}

active_block_scheduler() {
  local device="$1"
  local queue="/sys/block/$device/queue/scheduler"
  [[ -r "$queue" ]] || return 1
  sed -n 's/.*\[\([^]]*\)\].*/\1/p' "$queue"
}

available_block_schedulers() {
  local device="$1"
  local queue="/sys/block/$device/queue/scheduler"
  [[ -r "$queue" ]] || return 1
  tr ' ' '\n' < "$queue" | sed -n 's/^\[\(.*\)\]$/\1/p; t; /^[^[:space:]]\+$/p'
}

block_scheduler_state() {
  local active available device queue
  for device in "${block_devices[@]}"; do
    queue="/sys/block/$device/queue/scheduler"
    if [[ ! -r "$queue" ]]; then
      printf '%s=missing; ' "$device"
      continue
    fi
    active=$(active_block_scheduler "$device" || true)
    available=$(tr -s '[:space:]' ' ' < "$queue" | sed 's/[[:space:]]*$//')
    printf '%s=active:%s,available:%s; ' "$device" "$active" "$available"
  done
}

block_stat_state() {
  local device stat_file
  for device in "${block_devices[@]}"; do
    stat_file="/sys/block/$device/stat"
    if [[ -r "$stat_file" ]]; then
      printf '%s=%s; ' "$device" "$(tr -s '[:space:]' ' ' < "$stat_file" | sed 's/^ //; s/ $//')"
    else
      printf '%s=missing; ' "$device"
    fi
  done
}

storage_mount_state() {
  local path
  for path in "${storage_paths[@]}"; do
    if [[ ! -e "$path" ]]; then
      printf '%s=missing; ' "$path"
      continue
    fi
    if command -v findmnt >/dev/null 2>&1; then
      printf '%s=%s; ' "$path" "$(findmnt -T "$path" -n -o TARGET,SOURCE,FSTYPE,OPTIONS 2>/dev/null | tr '\t' ',' | tr -s ' ')"
    else
      printf '%s=dev:%s; ' "$path" "$(stat -c '%d' "$path" 2>/dev/null || true)"
    fi
  done
}

zfs_pool_iostats_state() {
  local file pool
  for file in /proc/spl/kstat/zfs/*/iostats; do
    [[ -r "$file" ]] || continue
    pool="${file%/iostats}"
    pool="${pool##*/}"
    printf '%s=' "$pool"
    awk '
      NR > 2 && $1 ~ /^(arc|direct)_(read|write)_(count|bytes)$/ {
        printf "%s:%s,", $1, $3
      }
      END { printf "; " }
    ' "$file"
  done
}

zfs_arc_state() {
  local file=/proc/spl/kstat/zfs/arcstats
  [[ -r "$file" ]] || return 0
  awk '
    NR > 2 && $1 ~ /^(size|c|hits|misses|demand_data_hits|demand_data_misses|prefetch_data_hits|prefetch_data_misses)$/ {
      printf "%s:%s,", $1, $3
    }
    END { printf "\n" }
  ' "$file"
}

save_block_scheduler_state() {
  local active device queue
  mkdir -p "$out/runtime-before/block-scheduler"
  for device in "${block_devices[@]}"; do
    queue="/sys/block/$device/queue/scheduler"
    [[ -r "$queue" ]] || die "missing block scheduler queue: $queue"
    active=$(active_block_scheduler "$device")
    [[ -n "$active" ]] || die "could not determine active scheduler for $device"
    printf '%s\n' "$active" > "$out/runtime-before/block-scheduler/$device"
  done
  block_scheduler_state > "$out/runtime-before/block-schedulers.txt"
}

restore_block_schedulers() {
  local device file queue scheduler
  [[ -d "$out/runtime-before/block-scheduler" ]] || return 0
  set +e
  for device in "${block_devices[@]}"; do
    file="$out/runtime-before/block-scheduler/$device"
    queue="/sys/block/$device/queue/scheduler"
    [[ -s "$file" && -w "$queue" ]] || continue
    scheduler=$(cat "$file")
    printf '%s\n' "$scheduler" > "$queue" 2>/dev/null || true
  done
  set -e
}

apply_block_scheduler() {
  local scheduler="$1"
  local device queue
  for device in "${block_devices[@]}"; do
    queue="/sys/block/$device/queue/scheduler"
    [[ -e "$queue" ]] || die "missing block scheduler queue: $queue"
    [[ -w "$queue" ]] || die "block scheduler queue is not writable: $queue"
    if ! available_block_schedulers "$device" | grep -Fxq -- "$scheduler"; then
      die "scheduler '$scheduler' is not available for $device: $(cat "$queue")"
    fi
    printf '%s\n' "$scheduler" > "$queue"
  done
}

save_msr_state() {
  local cpu msr
  mkdir -p "$out/msr-before"
  for cpu in $(expand_cpu_list "$cpus_for_msr"); do
    rdmsr -p "$cpu" 0xc8f > "$out/msr-before/pqr-cpu$cpu"
  done
  for msr in "${msrs[@]}"; do
    rdmsr -p 0 "$msr" > "$out/msr-before/mask-$msr"
  done
  pqr_state > "$out/msr-before/pqr.txt"
  mask_state > "$out/msr-before/masks.txt"
}

restore_msr_state() {
  local cpu msr file
  [[ -d "$out/msr-before" ]] || return 0
  set +e
  for cpu in $(expand_cpu_list "$cpus_for_msr"); do
    file="$out/msr-before/pqr-cpu$cpu"
    [[ -s "$file" ]] && wrmsr -p "$cpu" 0xc8f "$(hex "$(cat "$file")")"
  done
  for msr in "${msrs[@]}"; do
    file="$out/msr-before/mask-$msr"
    [[ -s "$file" ]] && wrmsr -a "$msr" "$(hex "$(cat "$file")")"
  done
  pqr_state > "$out/msr-after-restore-pqr.txt" 2>/dev/null
  mask_state > "$out/msr-after-restore-masks.txt" 2>/dev/null
  set -e
}

save_irq_state() {
  local irq state_dir
  state_dir="$out/runtime-before/irq"
  mkdir -p "$state_dir"
  cp /proc/irq/default_smp_affinity "$state_dir/default_smp_affinity" 2>/dev/null || true
  for irq in /proc/irq/[0-9]*; do
    [[ -r "$irq/smp_affinity_list" ]] || continue
    cat "$irq/smp_affinity_list" > "$state_dir/irq-${irq##*/}" 2>/dev/null || true
  done
}

restore_irq_state() {
  local file irq state_dir
  state_dir="$out/runtime-before/irq"
  [[ -d "$state_dir" ]] || return 0
  set +e
  if [[ -s "$state_dir/default_smp_affinity" && -w /proc/irq/default_smp_affinity ]]; then
    cat "$state_dir/default_smp_affinity" 2>/dev/null > /proc/irq/default_smp_affinity || true
  fi
  for file in "$state_dir"/irq-*; do
    [[ -s "$file" ]] || continue
    irq="${file##*/irq-}"
    [[ -w "/proc/irq/$irq/smp_affinity_list" ]] || continue
    cat "$file" 2>/dev/null > "/proc/irq/$irq/smp_affinity_list" || true
  done
  set -e
}

apply_irq_affinity() {
  local irq
  set +e
  if [[ -w /proc/irq/default_smp_affinity ]]; then
    printf '%s\n' "$irq_cpu_mask" 2>/dev/null > /proc/irq/default_smp_affinity || true
  fi
  for irq in /proc/irq/[0-9]*; do
    [[ -w "$irq/smp_affinity_list" ]] || continue
    printf '%s\n' "$housekeeping_cpus" 2>/dev/null > "$irq/smp_affinity_list" || true
  done
  set -e
}

save_power_file() {
  local path="$1"
  local name="$2"
  local state_dir="$out/runtime-before/power"
  [[ -r "$path" ]] || return 0
  cat "$path" > "$state_dir/$name" 2>/dev/null || true
}

restore_power_file() {
  local path="$1"
  local name="$2"
  local state_dir="$out/runtime-before/power"
  [[ -s "$state_dir/$name" && -w "$path" ]] || return 0
  cat "$state_dir/$name" 2>/dev/null > "$path" || true
}

save_power_state() {
  local cpu base file
  mkdir -p "$out/runtime-before/power"
  for cpu in $(expand_cpu_list "$cpus_for_msr"); do
    base=/sys/devices/system/cpu/cpu"$cpu"
    save_power_file "$base/cpufreq/scaling_governor" "cpu$cpu-scaling_governor"
    save_power_file "$base/cpufreq/energy_performance_preference" "cpu$cpu-energy_performance_preference"
    save_power_file "$base/power/energy_perf_bias" "cpu$cpu-energy_perf_bias"
  done
  for file in status no_turbo min_perf_pct max_perf_pct hwp_dynamic_boost; do
    save_power_file "/sys/devices/system/cpu/intel_pstate/$file" "intel_pstate-$file"
  done
}

restore_power_state() {
  local cpu base file
  [[ -d "$out/runtime-before/power" ]] || return 0
  set +e
  for cpu in $(expand_cpu_list "$cpus_for_msr"); do
    base=/sys/devices/system/cpu/cpu"$cpu"
    restore_power_file "$base/cpufreq/scaling_governor" "cpu$cpu-scaling_governor"
    restore_power_file "$base/cpufreq/energy_performance_preference" "cpu$cpu-energy_performance_preference"
    restore_power_file "$base/power/energy_perf_bias" "cpu$cpu-energy_perf_bias"
  done
  for file in status no_turbo min_perf_pct max_perf_pct hwp_dynamic_boost; do
    restore_power_file "/sys/devices/system/cpu/intel_pstate/$file" "intel_pstate-$file"
  done
  set -e
}

apply_power_policy() {
  local mode="$1"
  local cpu base
  set +e
  for cpu in $(expand_cpu_list "$cpus_for_msr"); do
    base=/sys/devices/system/cpu/cpu"$cpu"
    [[ -w "$base/cpufreq/scaling_governor" ]] &&
      printf 'performance\n' 2>/dev/null > "$base/cpufreq/scaling_governor"
    [[ -w "$base/cpufreq/energy_performance_preference" ]] &&
      printf 'performance\n' 2>/dev/null > "$base/cpufreq/energy_performance_preference"
    [[ -w "$base/power/energy_perf_bias" ]] &&
      printf '0\n' 2>/dev/null > "$base/power/energy_perf_bias"
  done
  [[ -w /sys/devices/system/cpu/intel_pstate/no_turbo ]] &&
    printf '0\n' 2>/dev/null > /sys/devices/system/cpu/intel_pstate/no_turbo
  [[ -w /sys/devices/system/cpu/intel_pstate/hwp_dynamic_boost ]] &&
    printf '1\n' 2>/dev/null > /sys/devices/system/cpu/intel_pstate/hwp_dynamic_boost
  if mode_has "$mode" maxperf; then
    [[ -w /sys/devices/system/cpu/intel_pstate/min_perf_pct ]] &&
      printf '100\n' 2>/dev/null > /sys/devices/system/cpu/intel_pstate/min_perf_pct
  fi
  set -e
}

apply_mode() {
  local mode="$1"
  local cpu scheduler
  if ((needs_block_scheduler)); then
    if scheduler=$(mode_scheduler "$mode"); then
      apply_block_scheduler "$scheduler"
    else
      restore_block_schedulers
    fi
  fi

  if ((needs_msr)); then
    if mode_has "$mode" house1; then
      wrmsr -a 0xc90 0xfff
      wrmsr -a 0xc91 0x1
      wrmsr -a 0xc92 0x7f
      wrmsr -a 0xc93 0x1ff
      for cpu in $(expand_cpu_list "$housekeeping_cpus"); do
        wrmsr -p "$cpu" 0xc8f 0x1
      done
      for cpu in $(expand_cpu_list "$workload_cpus"); do
        wrmsr -p "$cpu" 0xc8f 0x0
      done
    else
      wrmsr -a 0xc90 0xfff
      wrmsr -a 0xc91 0x7
      wrmsr -a 0xc92 0x7f
      wrmsr -a 0xc93 0x1ff
      for cpu in $(expand_cpu_list "$cpus_for_msr"); do
        wrmsr -p "$cpu" 0xc8f 0x0
      done
    fi
  fi

  if ((needs_irq)); then
    if mode_has "$mode" irq; then
      apply_irq_affinity
    else
      restore_irq_state
    fi
  fi

  if ((needs_power)); then
    if mode_has "$mode" perf || mode_has "$mode" maxperf; then
      apply_power_policy "$mode"
    else
      restore_power_state
    fi
  fi
}

stop_noise() {
  if [[ "$noise" != none ]]; then
    systemctl stop "$noise_unit" >/dev/null 2>&1 || true
    if [[ "$noise" == io && -n "$io_temp_path" ]]; then
      rmdir "$io_noise_dir" >/dev/null 2>&1 || true
    fi
  fi
}

cleanup() {
  local rc=$?
  stop_noise
  if ((needs_block_scheduler)); then
    restore_block_schedulers || true
  fi
  if ((needs_power)); then
    restore_power_state || true
  fi
  if ((needs_irq)); then
    restore_irq_state || true
  fi
  if ((needs_msr)); then
    restore_msr_state || true
  fi
  exit "$rc"
}
trap cleanup EXIT

cpu_state() {
  local cpu base
  for cpu in $(expand_cpu_list "$cpus_for_msr"); do
    base=/sys/devices/system/cpu/cpu"$cpu"/cpufreq
    if [[ -d "$base" ]]; then
      printf 'cpu%s:gov=%s,epp=%s,min=%s,max=%s,cur=%s ' \
        "$cpu" \
        "$(cat "$base/scaling_governor" 2>/dev/null || true)" \
        "$(cat "$base/energy_performance_preference" 2>/dev/null || true)" \
        "$(cat "$base/scaling_min_freq" 2>/dev/null || true)" \
        "$(cat "$base/scaling_max_freq" 2>/dev/null || true)" \
        "$(cat "$base/scaling_cur_freq" 2>/dev/null || true)"
    fi
  done
}

intel_pstate_state() {
  local base file
  base=/sys/devices/system/cpu/intel_pstate
  [[ -d "$base" ]] || return 0
  for file in status no_turbo min_perf_pct max_perf_pct hwp_dynamic_boost; do
    [[ -r "$base/$file" ]] || continue
    printf '%s=%s ' "$file" "$(cat "$base/$file" 2>/dev/null || true)"
  done
}

thp_state() {
  local base file
  base=/sys/kernel/mm/transparent_hugepage
  [[ -d "$base" ]] || return 0
  for file in enabled defrag use_zero_page; do
    [[ -r "$base/$file" ]] || continue
    printf '%s=%s\n' "$file" "$(cat "$base/$file" 2>/dev/null || true)"
  done
  for file in "$base"/khugepaged/*; do
    [[ -r "$file" ]] || continue
    printf 'khugepaged.%s=%s\n' "${file##*/}" "$(cat "$file" 2>/dev/null || true)"
  done
}

sysctl_state() {
  local path
  for path in \
    /proc/sys/kernel/numa_balancing \
    /proc/sys/kernel/sched_autogroup_enabled \
    /proc/sys/vm/compaction_proactiveness \
    /proc/sys/vm/swappiness; do
    [[ -r "$path" ]] || continue
    printf '%s=%s\n' "${path#/proc/sys/}" "$(cat "$path" 2>/dev/null || true)"
  done
}

unit_counters() {
  local unit vals
  if ! command -v systemctl >/dev/null 2>&1; then
    return 0
  fi
  for unit in "${services[@]}"; do
    vals=$(
      systemctl show "$unit" \
        -p ActiveState -p SubState -p MainPID -p ControlGroup -p EffectiveCPUs \
        -p CPUUsageNSec -p MemoryCurrent -p IOReadBytes -p IOWriteBytes \
        --value 2>/dev/null | tr '\n' ',' || true
    )
    printf '%s=%s ' "$unit" "$vals"
  done
}

noise_unit_state() {
  local vals
  [[ "$noise" != none ]] || return 0
  command -v systemctl >/dev/null 2>&1 || return 0
  vals=$(
    systemctl show "$noise_unit" \
      -p ActiveState -p SubState -p MainPID -p ControlGroup -p EffectiveCPUs \
      -p IOWeight -p CPUUsageNSec -p MemoryCurrent -p IOReadBytes -p IOWriteBytes \
      --value 2>/dev/null | tr '\n' ',' || true
  )
  printf '%s' "$vals"
}

psi_state() {
  local name="$1"
  if [[ -r "/proc/pressure/$name" ]]; then
    tr '\n' ';' < "/proc/pressure/$name"
  fi
}

sample_prompt() {
  local run_index="$1"
  if [[ "$prompt_set" == mixed ]]; then
    printf '%s' "${mixed_prompts[$(((run_index - 1) % ${#mixed_prompts[@]}))]}"
  else
    printf '%s' "$prompt"
  fi
}

snapshot_system() {
  local prefix="$1"
  {
    date -u
    hostname
    uname -a
    printf 'endpoint=%s\nmodel=%s\nprompt_set=%s\nmodes=%s\nsequence=%s\nrepeats=%s\nnoise=%s\n' \
      "$endpoint" "$model" "$prompt_set" "$modes_csv" "$sequence_csv" "$repeats" "$noise"
  } > "$out/$prefix-meta.txt"

  curl -fsS "$endpoint/health" > "$out/$prefix-health.json" 2>/dev/null || true
  curl -fsS "$endpoint/v1/models" > "$out/$prefix-models.json" 2>/dev/null || true
  cp /proc/loadavg "$out/$prefix-loadavg.txt" 2>/dev/null || true
  cp /proc/pressure/cpu "$out/$prefix-psi-cpu.txt" 2>/dev/null || true
  cp /proc/pressure/io "$out/$prefix-psi-io.txt" 2>/dev/null || true
  cp /proc/pressure/memory "$out/$prefix-psi-memory.txt" 2>/dev/null || true
  cat /sys/devices/virtual/workqueue/cpumask > "$out/$prefix-workqueue-cpumask.txt" 2>/dev/null || true
  cpu_state > "$out/$prefix-cpu-state.txt" 2>/dev/null || true
  intel_pstate_state > "$out/$prefix-intel-pstate.txt" 2>/dev/null || true
  thp_state > "$out/$prefix-thp.txt" 2>/dev/null || true
  sysctl_state > "$out/$prefix-sysctl.txt" 2>/dev/null || true
  pqr_state > "$out/$prefix-pqr.txt" 2>/dev/null || true
  mask_state > "$out/$prefix-masks.txt" 2>/dev/null || true
  block_scheduler_state > "$out/$prefix-block-schedulers.txt" 2>/dev/null || true
  block_stat_state > "$out/$prefix-block-stats.txt" 2>/dev/null || true
  storage_mount_state > "$out/$prefix-storage-mounts.txt" 2>/dev/null || true
  zfs_pool_iostats_state > "$out/$prefix-zfs-pool-iostats.txt" 2>/dev/null || true
  zfs_arc_state > "$out/$prefix-zfs-arc.txt" 2>/dev/null || true
  if command -v zpool >/dev/null 2>&1; then
    zpool iostat -p -v -H > "$out/$prefix-zpool-iostat.tsv" 2>/dev/null || true
  fi
  unit_counters > "$out/$prefix-unit-counters.txt" 2>/dev/null || true
  noise_unit_state > "$out/$prefix-noise-unit-counters.txt" 2>/dev/null || true

  if command -v systemctl >/dev/null 2>&1; then
    systemctl show system.slice user.slice llm-workload.slice llama-cpp.service "${services[@]}" \
      -p Id -p ActiveState -p SubState -p MainPID -p ControlGroup -p AllowedCPUs -p EffectiveCPUs \
      -p CPUUsageNSec -p MemoryCurrent -p IOReadBytes -p IOWriteBytes \
      > "$out/$prefix-systemd-state.txt" 2>/dev/null || true
  fi

  ps -eo pid,ppid,psr,pcpu,pmem,comm,args --sort=-pcpu \
    > "$out/$prefix-ps-cpu.txt" 2>/dev/null || true

  if [[ -d /proc/irq ]]; then
    local irq_actions
    for irq in /proc/irq/[0-9]*; do
      [[ -r "$irq/smp_affinity_list" ]] || continue
      irq_actions=
      if [[ -r "$irq/actions" ]]; then
        irq_actions=$(tr -d '\n' < "$irq/actions")
      fi
      printf '%s\t%s\t%s\n' \
        "${irq##*/}" \
        "$(cat "$irq/smp_affinity_list" 2>/dev/null || true)" \
        "$irq_actions"
    done > "$out/$prefix-irq-affinity.tsv" || true
  fi
}

start_noise() {
  [[ "$noise" != none ]] || return 0
  local taskset_path stress_ng_path noise_state
  local -a systemd_props
  taskset_path=$(command -v taskset)
  stress_ng_path=$(command -v stress-ng)
  systemd_props=(
    --property=AllowedCPUs="$housekeeping_cpus"
    --property=MemoryAccounting=yes
  )
  if [[ -n "$noise_io_weight" ]]; then
    systemd_props+=(--property=IOWeight="$noise_io_weight")
  fi

  case "$noise" in
    cache)
      systemd-run \
        --unit="$noise_unit" \
        --collect \
        "${systemd_props[@]}" \
        "$taskset_path" -c "$housekeeping_cpus" \
        "$stress_ng_path" --cache 2 --cache-level 3 --cache-size "$cache_size" \
          --cache-no-affinity --timeout "$noise_duration" --metrics-brief \
        > "$out/noise-systemd-run.txt" 2>&1
      ;;
    io)
      mkdir -p "$io_noise_dir"
      systemd-run \
        --unit="$noise_unit" \
        --collect \
        "${systemd_props[@]}" \
        --property=IOAccounting=yes \
        "$taskset_path" -c "$housekeeping_cpus" \
        "$stress_ng_path" --temp-path "$io_noise_dir" \
          --hdd "$io_workers" --hdd-bytes "$io_bytes" --hdd-opts "$io_opts" \
          --timeout "$noise_duration" --metrics-brief \
        > "$out/noise-systemd-run.txt" 2>&1
      ;;
  esac
  sleep 4
  systemctl show "$noise_unit" -p Id -p ActiveState -p ControlGroup -p AllowedCPUs -p EffectiveCPUs -p IOWeight \
    > "$out/noise-unit-state.txt" 2>/dev/null || true
  noise_state=$(systemctl show "$noise_unit" -p ActiveState --value 2>/dev/null || true)
  if [[ "$noise_state" != active ]]; then
    journalctl -u "$noise_unit" -n 80 --no-pager -o cat > "$out/noise-journal.txt" 2>/dev/null || true
    die "$noise noise unit $noise_unit is not active; see $out/noise-journal.txt"
  fi
}

run_sample() {
  local mode="$1"
  local run_index="$2"
  local seed=$((seed_base + run_index))
  local response
  local payload start end wall_ms
  local prompt_text prompt_index
  local before_load after_load before_cpu before_pqr before_masks before_units
  local before_block_schedulers before_block_stats before_storage_mounts
  local after_block_schedulers after_block_stats after_storage_mounts
  local before_zfs_arc before_zfs_iostats after_zfs_arc after_zfs_iostats
  local before_intel_pstate after_intel_pstate
  local before_noise_unit after_noise_unit
  local before_psi_cpu before_psi_io before_psi_memory
  local after_cpu after_pqr after_masks after_units
  local after_psi_cpu after_psi_io after_psi_memory

  response="$out/responses/$(printf '%03d' "$run_index")-$mode.json"
  prompt_text=$(sample_prompt "$run_index")
  if [[ "$prompt_set" == mixed ]]; then
    prompt_index=$((((run_index - 1) % ${#mixed_prompts[@]}) + 1))
  else
    prompt_index=1
  fi

  apply_mode "$mode"
  sleep 1

  before_load=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || true)
  before_cpu=$(cpu_state)
  before_intel_pstate=$(intel_pstate_state)
  before_pqr=$(pqr_state)
  before_masks=$(mask_state)
  before_block_schedulers=$(block_scheduler_state)
  before_block_stats=$(block_stat_state)
  before_storage_mounts=$(storage_mount_state)
  before_zfs_iostats=$(zfs_pool_iostats_state)
  before_zfs_arc=$(zfs_arc_state)
  before_units=$(unit_counters)
  before_noise_unit=$(noise_unit_state)
  before_psi_cpu=$(psi_state cpu)
  before_psi_io=$(psi_state io)
  before_psi_memory=$(psi_state memory)

  payload=$(
    jq -nc \
      --arg model "$model" \
      --arg prompt "$prompt_text" \
      --argjson max_tokens "$max_tokens" \
      --argjson seed "$seed" \
      '{model:$model, messages:[{role:"user",content:$prompt}], max_tokens:$max_tokens, temperature:0, seed:$seed, stream:false}'
  )

  start=$(date +%s%3N)
  curl -fsS --max-time 180 "$endpoint/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d "$payload" > "$response"
  end=$(date +%s%3N)
  wall_ms=$((end - start))

  after_load=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || true)
  after_cpu=$(cpu_state)
  after_intel_pstate=$(intel_pstate_state)
  after_pqr=$(pqr_state)
  after_masks=$(mask_state)
  after_block_schedulers=$(block_scheduler_state)
  after_block_stats=$(block_stat_state)
  after_storage_mounts=$(storage_mount_state)
  after_zfs_iostats=$(zfs_pool_iostats_state)
  after_zfs_arc=$(zfs_arc_state)
  after_units=$(unit_counters)
  after_noise_unit=$(noise_unit_state)
  after_psi_cpu=$(psi_state cpu)
  after_psi_io=$(psi_state io)
  after_psi_memory=$(psi_state memory)

  jq -c \
    --arg mode "$mode" \
    --arg prompt_set "$prompt_set" \
    --arg prompt "$prompt_text" \
    --argjson run_index "$run_index" \
    --argjson prompt_index "$prompt_index" \
    --argjson seed "$seed" \
    --arg pqr_before "$before_pqr" \
    --arg pqr_after "$after_pqr" \
    --arg masks_before "$before_masks" \
    --arg masks_after "$after_masks" \
    --arg block_schedulers_before "$before_block_schedulers" \
    --arg block_schedulers_after "$after_block_schedulers" \
    --arg block_stats_before "$before_block_stats" \
    --arg block_stats_after "$after_block_stats" \
    --arg storage_mounts_before "$before_storage_mounts" \
    --arg storage_mounts_after "$after_storage_mounts" \
    --arg zfs_pool_iostats_before "$before_zfs_iostats" \
    --arg zfs_pool_iostats_after "$after_zfs_iostats" \
    --arg zfs_arc_before "$before_zfs_arc" \
    --arg zfs_arc_after "$after_zfs_arc" \
    --arg cpu_before "$before_cpu" \
    --arg cpu_after "$after_cpu" \
    --arg intel_pstate_before "$before_intel_pstate" \
    --arg intel_pstate_after "$after_intel_pstate" \
    --arg load_before "$before_load" \
    --arg load_after "$after_load" \
    --arg units_before "$before_units" \
    --arg units_after "$after_units" \
    --arg noise_unit_before "$before_noise_unit" \
    --arg noise_unit_after "$after_noise_unit" \
    --arg psi_cpu_before "$before_psi_cpu" \
    --arg psi_cpu_after "$after_psi_cpu" \
    --arg psi_io_before "$before_psi_io" \
    --arg psi_io_after "$after_psi_io" \
    --arg psi_memory_before "$before_psi_memory" \
    --arg psi_memory_after "$after_psi_memory" \
    --argjson wall_ms "$wall_ms" \
    '{
      mode:$mode,
      prompt_set:$prompt_set,
      prompt_index:$prompt_index,
      prompt:$prompt,
      run_index:$run_index,
      seed:$seed,
      wall_ms:$wall_ms,
      pqr_before:$pqr_before,
      pqr_after:$pqr_after,
      masks_before:$masks_before,
      masks_after:$masks_after,
      block_schedulers_before:$block_schedulers_before,
      block_schedulers_after:$block_schedulers_after,
      block_stats_before:$block_stats_before,
      block_stats_after:$block_stats_after,
      storage_mounts_before:$storage_mounts_before,
      storage_mounts_after:$storage_mounts_after,
      zfs_pool_iostats_before:$zfs_pool_iostats_before,
      zfs_pool_iostats_after:$zfs_pool_iostats_after,
      zfs_arc_before:$zfs_arc_before,
      zfs_arc_after:$zfs_arc_after,
      cpu_before:$cpu_before,
      cpu_after:$cpu_after,
      intel_pstate_before:$intel_pstate_before,
      intel_pstate_after:$intel_pstate_after,
      load_before:$load_before,
      load_after:$load_after,
      units_before:$units_before,
      units_after:$units_after,
      noise_unit_before:$noise_unit_before,
      noise_unit_after:$noise_unit_after,
      psi_cpu_before:$psi_cpu_before,
      psi_cpu_after:$psi_cpu_after,
      psi_io_before:$psi_io_before,
      psi_io_after:$psi_io_after,
      psi_memory_before:$psi_memory_before,
      psi_memory_after:$psi_memory_after,
      prompt_tps:(.timings.prompt_per_second // null),
      generation_tps:(.timings.predicted_per_second // null),
      prompt_tokens:(.timings.prompt_n // .usage.prompt_tokens // null),
      generated_tokens:(.timings.predicted_n // .usage.completion_tokens // null),
      total_tokens:(.usage.total_tokens // null),
      finish_reason:(.choices[0].finish_reason // null)
    }' "$response" >> "$out/results.jsonl"
}

write_summary() {
  jq -s '
    def avg: if length == 0 then null else add / length end;
    def median:
      sort as $s
      | if length == 0 then null
        elif (length % 2) == 1 then $s[(length / 2 | floor)]
        else (($s[(length / 2) - 1] + $s[length / 2]) / 2)
        end;
    group_by(.mode)
    | map({
        mode: .[0].mode,
        n: length,
        avg: (map(.generation_tps) | avg),
        median: (map(.generation_tps) | median),
        min: (map(.generation_tps) | min),
        max: (map(.generation_tps) | max),
        spread: ((map(.generation_tps) | max) - (map(.generation_tps) | min)),
        wall_avg_ms: (map(.wall_ms) | avg),
        rows: .
      })' "$out/results.jsonl" > "$out/summary.json"

  {
    printf 'mode\tn\tavg_tps\tmedian_tps\tmin_tps\tmax_tps\tspread\twall_avg_ms\n'
    jq -r '.[] | [.mode, .n, .avg, .median, .min, .max, .spread, .wall_avg_ms] | @tsv' "$out/summary.json"
  } > "$out/summary.tsv"

  jq -s '
    def avg: if length == 0 then null else add / length end;
    def median:
      sort as $s
      | if length == 0 then null
        elif (length % 2) == 1 then $s[(length / 2 | floor)]
        else (($s[(length / 2) - 1] + $s[length / 2]) / 2)
        end;
    sort_by(.prompt_index, .mode)
    | group_by([.prompt_index, .mode])
    | map({
        prompt_index: .[0].prompt_index,
        prompt: .[0].prompt,
        mode: .[0].mode,
        n: length,
        avg: (map(.generation_tps) | avg),
        median: (map(.generation_tps) | median),
        min: (map(.generation_tps) | min),
        max: (map(.generation_tps) | max),
        spread: ((map(.generation_tps) | max) - (map(.generation_tps) | min)),
        wall_avg_ms: (map(.wall_ms) | avg)
      })' "$out/results.jsonl" > "$out/prompt-summary.json"

  {
    printf 'prompt_index\tmode\tn\tavg_tps\tmedian_tps\tmin_tps\tmax_tps\tspread\twall_avg_ms\tprompt\n'
    jq -r '.[] | [.prompt_index, .mode, .n, .avg, .median, .min, .max, .spread, .wall_avg_ms, .prompt] | @tsv' "$out/prompt-summary.json"
  } > "$out/prompt-summary.tsv"

  jq -s '
    def avg: if length == 0 then null else add / length end;
    def median:
      sort as $s
      | if length == 0 then null
        elif (length % 2) == 1 then $s[(length / 2 | floor)]
        else (($s[(length / 2) - 1] + $s[length / 2]) / 2)
        end;
    sort_by(.prompt_index)
    | group_by(.prompt_index)
    | map(
        . as $rows
        | ($rows
          | sort_by(.mode)
          | group_by(.mode)
          | map({
              key: .[0].mode,
              value: {
                n: length,
                avg: (map(.generation_tps) | avg),
                median: (map(.generation_tps) | median),
                min: (map(.generation_tps) | min),
                max: (map(.generation_tps) | max)
              }
            })
          | from_entries) as $by
        | {
            prompt_index: $rows[0].prompt_index,
            prompt: $rows[0].prompt,
            none_n: ($by.none.n // null),
            house1_n: ($by.house1.n // null),
            none_avg: ($by.none.avg // null),
            house1_avg: ($by.house1.avg // null),
            house1_minus_none_tps: (
              if ($by | has("none") and has("house1"))
              then $by.house1.avg - $by.none.avg
              else null
              end
            ),
            house1_minus_none_pct: (
              if ($by | has("none") and has("house1") and $by.none.avg != 0)
              then (($by.house1.avg - $by.none.avg) / $by.none.avg * 100)
              else null
              end
            ),
            none_median: ($by.none.median // null),
            house1_median: ($by.house1.median // null),
            house1_minus_none_median_tps: (
              if ($by | has("none") and has("house1"))
              then $by.house1.median - $by.none.median
              else null
              end
            )
          }
      )' "$out/results.jsonl" > "$out/paired-deltas.json"

  {
    printf 'prompt_index\tnone_n\thouse1_n\tnone_avg\thouse1_avg\thouse1_minus_none_tps\thouse1_minus_none_pct\tnone_median\thouse1_median\thouse1_minus_none_median_tps\tprompt\n'
    jq -r '.[] | [.prompt_index, .none_n, .house1_n, .none_avg, .house1_avg, .house1_minus_none_tps, .house1_minus_none_pct, .none_median, .house1_median, .house1_minus_none_median_tps, .prompt] | @tsv' "$out/paired-deltas.json"
  } > "$out/paired-deltas.tsv"

  jq -s '
    def avg: if length == 0 then null else add / length end;
    def median:
      sort as $s
      | if length == 0 then null
        elif (length % 2) == 1 then $s[(length / 2 | floor)]
        else (($s[(length / 2) - 1] + $s[length / 2]) / 2)
        end;
    [
      sort_by(.prompt_index, .mode)
      | group_by(.prompt_index)[]
      | . as $rows
      | ($rows
        | sort_by(.mode)
        | group_by(.mode)
        | map({
            key: .[0].mode,
            value: {
              n: length,
              avg: (map(.generation_tps) | avg),
              median: (map(.generation_tps) | median),
              min: (map(.generation_tps) | min),
              max: (map(.generation_tps) | max)
            }
          })
        | from_entries) as $by
      | ($by.none // null) as $base
      | $by
      | to_entries[]
      | select(.key != "none")
      | {
          prompt_index: $rows[0].prompt_index,
          prompt: $rows[0].prompt,
          mode: .key,
          baseline_n: ($base.n // null),
          mode_n: .value.n,
          baseline_avg: ($base.avg // null),
          mode_avg: .value.avg,
          mode_minus_none_tps: (
            if $base == null then null else .value.avg - $base.avg end
          ),
          mode_minus_none_pct: (
            if ($base == null or $base.avg == 0) then null
            else ((.value.avg - $base.avg) / $base.avg * 100)
            end
          ),
          baseline_median: ($base.median // null),
          mode_median: .value.median,
          mode_minus_none_median_tps: (
            if $base == null then null else .value.median - $base.median end
          )
        }
    ]' "$out/results.jsonl" > "$out/mode-deltas.json"

  {
    printf 'prompt_index\tmode\tbaseline_n\tmode_n\tbaseline_avg\tmode_avg\tmode_minus_none_tps\tmode_minus_none_pct\tbaseline_median\tmode_median\tmode_minus_none_median_tps\tprompt\n'
    jq -r '.[] | [.prompt_index, .mode, .baseline_n, .mode_n, .baseline_avg, .mode_avg, .mode_minus_none_tps, .mode_minus_none_pct, .baseline_median, .mode_median, .mode_minus_none_median_tps, .prompt] | @tsv' "$out/mode-deltas.json"
  } > "$out/mode-deltas.tsv"
}

{
  printf 'out=%s\n' "$out"
  printf 'endpoint=%s\n' "$endpoint"
  printf 'model=%s\n' "$model"
  printf 'prompt_set=%s\n' "$prompt_set"
  printf 'modes=%s\n' "$modes_csv"
  printf 'sequence=%s\n' "$sequence_csv"
  printf 'repeats=%s\n' "$repeats"
  printf 'noise=%s\n' "$noise"
  printf 'housekeeping_cpus=%s\n' "$housekeeping_cpus"
  printf 'irq_cpu_mask=%s\n' "$irq_cpu_mask"
  printf 'workload_cpus=%s\n' "$workload_cpus"
  printf 'block_devices=%s\n' "$block_devices_csv"
  printf 'storage_paths=%s\n' "$(IFS=','; printf '%s' "${storage_paths[*]}")"
  printf 'max_tokens=%s\n' "$max_tokens"
  printf 'seed_base=%s\n' "$seed_base"
  printf 'cache_size=%s\n' "$cache_size"
  printf 'io_workers=%s\n' "$io_workers"
  printf 'io_bytes=%s\n' "$io_bytes"
  printf 'io_opts=%s\n' "$io_opts"
  printf 'io_temp_path=%s\n' "$io_temp_path"
  printf 'io_noise_dir=%s\n' "$io_noise_dir"
  printf 'noise_io_weight=%s\n' "$noise_io_weight"
} > "$out/run-params.env"

if ((needs_block_scheduler)); then
  save_block_scheduler_state
fi
snapshot_system before
if ((needs_msr)); then
  save_msr_state
fi
if ((needs_irq)); then
  save_irq_state
fi
if ((needs_power)); then
  save_power_state
fi
start_noise

run_index=0
if [[ -n "$sequence_csv" ]]; then
  for mode in "${schedule[@]}"; do
    run_index=$((run_index + 1))
    printf '== sample=%s/%s mode=%s ==\n' "$run_index" "${#schedule[@]}" "$mode" | tee -a "$out/run.log"
    run_sample "$mode" "$run_index"
  done
else
  for ((round = 1; round <= repeats; round++)); do
    for mode in "${configured_modes[@]}"; do
      run_index=$((run_index + 1))
      printf '== %s/%s mode=%s ==\n' "$round" "$repeats" "$mode" | tee -a "$out/run.log"
      run_sample "$mode" "$run_index"
    done
  done
fi

write_summary
if ((needs_block_scheduler)); then
  restore_block_schedulers
fi
if ((needs_power)); then
  restore_power_state
fi
if ((needs_irq)); then
  restore_irq_state
fi
if ((needs_msr)); then
  restore_msr_state
fi
snapshot_system after
printf '%s\n' "$out"
cat "$out/summary.tsv"
