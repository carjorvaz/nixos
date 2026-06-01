#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  llm-cluster-llama-bench.bash --model PATH [options]

Run llama-bench or ik_llama.cpp's llama-bench over a small, explicit matrix and
write raw JSON plus TSV summaries. Intended for single-node baselines before
the distributed experiments start.

Options:
  --model PATH          required GGUF model path
  --binary SPEC         binary to test; repeatable. SPEC may be PATH or
                        LABEL=PATH. Default: llama-bench from PATH
  --threads CSV         thread counts; default: detected physical cores,half,all
  --prompt-tokens CSV   prompt token counts for prompt-processing tests;
                        default: 128,512
  --gen-tokens CSV      generated token counts for token-generation tests;
                        default: 64,128
  --batch CSV           batch sizes; default: 512
  --ubatch CSV          microbatch sizes; default: 512
  --repeats N           llama-bench repetitions per case; default: 3
  --ctx N               context size; default: 2048
  --ngl N               GPU layers; default: 0
  --extra-arg ARG       extra argument appended to every llama-bench call;
                        may be repeated
  --out-root DIR        output parent; default: /tmp/llm-cluster-llama-bench
  --label NAME          run directory label; default: llama-bench
  --dry-run             print commands without executing them
  -h, --help            show this help

Examples:
  tools/llm-cluster-llama-bench.bash \
    --model /persist/models/qwen.gguf \
    --binary ik-avx2=/nix/store/...-ik-llama-avx2-*/bin/llama-bench \
    --threads 4,8 --prompt-tokens 512 --gen-tokens 128

  ssh trajanus 'bash -s -- --model /persist/models/qwen.gguf --threads 4,8,16' \
    < tools/llm-cluster-llama-bench.bash
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

safe_name() {
  local value="$1"
  value="${value//[^A-Za-z0-9_.-]/_}"
  printf '%s' "$value"
}

csv_to_array() {
  local csv="$1"
  local -n array_ref="$2"
  local item
  IFS=',' read -ra array_ref <<< "$csv"
  for item in "${array_ref[@]}"; do
    [[ -n "$item" ]] || die "empty item in CSV: $csv"
  done
}

detected_threads_csv() {
  local cpus cores half
  cpus=$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1')
  cores=$(
    lscpu 2>/dev/null | awk -F: '
      /^Core\(s\) per socket:/ { gsub(/^[ \t]+/, "", $2); cores = $2 }
      /^Socket\(s\):/ { gsub(/^[ \t]+/, "", $2); sockets = $2 }
      END {
        if (cores > 0 && sockets > 0) print cores * sockets
      }'
  )
  [[ -n "$cores" ]] || cores="$cpus"
  half=$((cores / 2))
  ((half >= 1)) || half=1
  if ((half == cores)); then
    printf '%s\n' "$cores"
  else
    printf '%s,%s,%s\n' "$half" "$cores" "$cpus"
  fi
}

write_system_snapshot() {
  local prefix="$1"
  local dir="$2"

  {
    date -u +%Y-%m-%dT%H:%M:%SZ
    hostname 2>/dev/null || true
    uname -a 2>/dev/null || true
  } > "$dir/$prefix-identity.txt"

  lscpu > "$dir/$prefix-lscpu.txt" 2>/dev/null || true
  free -h > "$dir/$prefix-free.txt" 2>/dev/null || true
  cat /proc/meminfo > "$dir/$prefix-meminfo.txt" 2>/dev/null || true
  cat /proc/loadavg > "$dir/$prefix-loadavg.txt" 2>/dev/null || true
  cat /proc/pressure/cpu > "$dir/$prefix-psi-cpu.txt" 2>/dev/null || true
  cat /proc/pressure/io > "$dir/$prefix-psi-io.txt" 2>/dev/null || true
  cat /proc/pressure/memory > "$dir/$prefix-psi-memory.txt" 2>/dev/null || true
  numactl --hardware > "$dir/$prefix-numactl.txt" 2>/dev/null || true
  cpupower frequency-info > "$dir/$prefix-cpupower.txt" 2>/dev/null || true
  sensors > "$dir/$prefix-sensors.txt" 2>/dev/null || true
  tlp-stat -s -b -p > "$dir/$prefix-tlp.txt" 2>/dev/null || true
  lsblk -o NAME,MODEL,SERIAL,TRAN,RM,ROTA,SIZE,FSTYPE,MOUNTPOINTS \
    > "$dir/$prefix-lsblk.txt" 2>/dev/null || true

  if [[ -d /sys/devices/system/cpu ]]; then
    {
      for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
        [[ -d "$cpu/cpufreq" ]] || continue
        printf '%s\tgovernor=%s\tepp=%s\tcur=%s\tmin=%s\tmax=%s\n' \
          "${cpu##*/}" \
          "$(cat "$cpu/cpufreq/scaling_governor" 2>/dev/null || true)" \
          "$(cat "$cpu/cpufreq/energy_performance_preference" 2>/dev/null || true)" \
          "$(cat "$cpu/cpufreq/scaling_cur_freq" 2>/dev/null || true)" \
          "$(cat "$cpu/cpufreq/scaling_min_freq" 2>/dev/null || true)" \
          "$(cat "$cpu/cpufreq/scaling_max_freq" 2>/dev/null || true)"
      done
    } > "$dir/$prefix-cpufreq.tsv" 2>/dev/null || true
  fi
}

model=
threads_csv=
prompt_tokens_csv=128,512
gen_tokens_csv=64,128
batch_csv=512
ubatch_csv=512
repeats=3
ctx=2048
ngl=0
out_root=/tmp/llm-cluster-llama-bench
label=llama-bench
dry_run=false
binaries=()
extra_args=()

while (($# > 0)); do
  case "$1" in
    --model) model="$2"; shift 2 ;;
    --model=*) model="${1#*=}"; shift ;;
    --binary) binaries+=("$2"); shift 2 ;;
    --binary=*) binaries+=("${1#*=}"); shift ;;
    --threads) threads_csv="$2"; shift 2 ;;
    --threads=*) threads_csv="${1#*=}"; shift ;;
    --prompt-tokens) prompt_tokens_csv="$2"; shift 2 ;;
    --prompt-tokens=*) prompt_tokens_csv="${1#*=}"; shift ;;
    --gen-tokens) gen_tokens_csv="$2"; shift 2 ;;
    --gen-tokens=*) gen_tokens_csv="${1#*=}"; shift ;;
    --batch) batch_csv="$2"; shift 2 ;;
    --batch=*) batch_csv="${1#*=}"; shift ;;
    --ubatch) ubatch_csv="$2"; shift 2 ;;
    --ubatch=*) ubatch_csv="${1#*=}"; shift ;;
    --repeats) repeats="$2"; shift 2 ;;
    --repeats=*) repeats="${1#*=}"; shift ;;
    --ctx) ctx="$2"; shift 2 ;;
    --ctx=*) ctx="${1#*=}"; shift ;;
    --ngl) ngl="$2"; shift 2 ;;
    --ngl=*) ngl="${1#*=}"; shift ;;
    --extra-arg) extra_args+=("$2"); shift 2 ;;
    --extra-arg=*) extra_args+=("${1#*=}"); shift ;;
    --out-root) out_root="$2"; shift 2 ;;
    --out-root=*) out_root="${1#*=}"; shift ;;
    --label) label="$2"; shift 2 ;;
    --label=*) label="${1#*=}"; shift ;;
    --dry-run) dry_run=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$model" ]] || die "--model is required"
[[ -r "$model" ]] || die "model is not readable: $model"
[[ "$repeats" =~ ^[0-9]+$ && "$repeats" -gt 0 ]] || die "--repeats must be a positive integer"
[[ "$ctx" =~ ^[0-9]+$ && "$ctx" -gt 0 ]] || die "--ctx must be a positive integer"
[[ "$ngl" =~ ^[0-9]+$ ]] || die "--ngl must be a non-negative integer"
[[ "$label" =~ ^[A-Za-z0-9_.-]+$ ]] || die "--label may only contain letters, numbers, dot, underscore, and dash"

require date jq mkdir awk sed getconf
if ((${#binaries[@]} == 0)); then
  command -v llama-bench >/dev/null 2>&1 || die "llama-bench is not in PATH; pass --binary PATH"
  binaries=("llama-bench=$(command -v llama-bench)")
fi
if [[ -z "$threads_csv" ]]; then
  threads_csv="$(detected_threads_csv)"
fi

declare -a threads prompt_tokens gen_tokens batches ubatches
csv_to_array "$threads_csv" threads
csv_to_array "$prompt_tokens_csv" prompt_tokens
csv_to_array "$gen_tokens_csv" gen_tokens
csv_to_array "$batch_csv" batches
csv_to_array "$ubatch_csv" ubatches

for value in "${threads[@]}" "${prompt_tokens[@]}" "${gen_tokens[@]}" "${batches[@]}" "${ubatches[@]}"; do
  [[ "$value" =~ ^[0-9]+$ && "$value" -gt 0 ]] || die "matrix values must be positive integers: $value"
done

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
run_dir="$out_root/${label}-${timestamp}"
mkdir -p "$run_dir"/{raw,stderr,system}

{
  printf 'timestamp_utc=%s\n' "$timestamp"
  printf 'host=%s\n' "$(hostname 2>/dev/null || true)"
  printf 'model=%s\n' "$model"
  printf 'model_bytes=%s\n' "$(stat -c %s "$model" 2>/dev/null || stat -f %z "$model" 2>/dev/null || true)"
  printf 'binaries=%s\n' "$(IFS=','; printf '%s' "${binaries[*]}")"
  printf 'threads=%s\n' "$threads_csv"
  printf 'prompt_tokens=%s\n' "$prompt_tokens_csv"
  printf 'gen_tokens=%s\n' "$gen_tokens_csv"
  printf 'batch=%s\n' "$batch_csv"
  printf 'ubatch=%s\n' "$ubatch_csv"
  printf 'repeats=%s\n' "$repeats"
  printf 'ctx=%s\n' "$ctx"
  printf 'ngl=%s\n' "$ngl"
  printf 'extra_args=%s\n' "$(IFS=' '; printf '%s' "${extra_args[*]}")"
} > "$run_dir/manifest.env"

write_system_snapshot before "$run_dir/system"
: > "$run_dir/results.jsonl"
printf 'case_id\tbinary_label\tthreads\tprompt_tokens\tgen_tokens\tbatch\tubatch\tstatus\traw_file\tstderr_file\n' \
  > "$run_dir/cases.tsv"

case_index=0
for binary_spec in "${binaries[@]}"; do
  if [[ "$binary_spec" == *=* ]]; then
    binary_label="${binary_spec%%=*}"
    binary_path="${binary_spec#*=}"
  else
    binary_path="$binary_spec"
    binary_label="$(safe_name "${binary_path##*/}")"
  fi
  [[ -x "$binary_path" ]] || die "binary is not executable: $binary_path"
  binary_label="$(safe_name "$binary_label")"

  "$binary_path" --version > "$run_dir/system/${binary_label}-version.txt" 2>&1 || true

  for thread_count in "${threads[@]}"; do
    for prompt_count in "${prompt_tokens[@]}"; do
      for gen_count in "${gen_tokens[@]}"; do
        for batch in "${batches[@]}"; do
          for ubatch in "${ubatches[@]}"; do
            case_index=$((case_index + 1))
            case_id="$(printf '%03d' "$case_index")-${binary_label}-t${thread_count}-p${prompt_count}-n${gen_count}-b${batch}-ub${ubatch}"
            raw_file="$run_dir/raw/${case_id}.json"
            stderr_file="$run_dir/stderr/${case_id}.stderr"
            status=ok
            cmd=(
              "$binary_path"
              -m "$model"
              -p "$prompt_count"
              -n "$gen_count"
              -t "$thread_count"
              -b "$batch"
              -ub "$ubatch"
              -r "$repeats"
              -c "$ctx"
              -ngl "$ngl"
              -o json
            )
            cmd+=("${extra_args[@]}")

            printf '== %s ==\n' "$case_id" | tee -a "$run_dir/run.log"
            printf '%q ' "${cmd[@]}" >> "$run_dir/commands.sh"
            printf '\n' >> "$run_dir/commands.sh"

            if [[ "$dry_run" == true ]]; then
              printf 'dry-run\n' > "$raw_file"
              status=dry_run
            elif ! "${cmd[@]}" > "$raw_file" 2> "$stderr_file"; then
              status=failed
            fi

            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
              "$case_id" "$binary_label" "$thread_count" "$prompt_count" "$gen_count" "$batch" "$ubatch" "$status" "$raw_file" "$stderr_file" \
              >> "$run_dir/cases.tsv"

            if [[ "$status" == ok ]]; then
              jq -c \
                --arg case_id "$case_id" \
                --arg binary_label "$binary_label" \
                --arg binary_path "$binary_path" \
                --arg raw_file "$raw_file" \
                --arg stderr_file "$stderr_file" \
                --argjson threads "$thread_count" \
                --argjson prompt_tokens "$prompt_count" \
                --argjson gen_tokens "$gen_count" \
                --argjson batch "$batch" \
                --argjson ubatch "$ubatch" \
                '.[] | {
                  case_id:$case_id,
                  binary_label:$binary_label,
                  binary_path:$binary_path,
                  threads:$threads,
                  prompt_tokens:$prompt_tokens,
                  gen_tokens:$gen_tokens,
                  batch:$batch,
                  ubatch:$ubatch,
                  status:"ok",
                  raw_file:$raw_file,
                  stderr_file:$stderr_file,
                  llama:.
                }' "$raw_file" >> "$run_dir/results.jsonl" || {
                status=parse_failed
                printf '%s\t%s\n' "$case_id" "$raw_file" >> "$run_dir/parse-failures.tsv"
              }
            fi

            if [[ "$status" != ok ]]; then
              stderr_tail="$(tail -n 80 "$stderr_file" 2>/dev/null || true)"
              jq -nc \
                --arg case_id "$case_id" \
                --arg binary_label "$binary_label" \
                --arg binary_path "$binary_path" \
                --arg raw_file "$raw_file" \
                --arg stderr_file "$stderr_file" \
                --arg status "$status" \
                --arg stderr_tail "$stderr_tail" \
                --argjson threads "$thread_count" \
                --argjson prompt_tokens "$prompt_count" \
                --argjson gen_tokens "$gen_count" \
                --argjson batch "$batch" \
                --argjson ubatch "$ubatch" \
                '{
                  case_id:$case_id,
                  binary_label:$binary_label,
                  binary_path:$binary_path,
                  threads:$threads,
                  prompt_tokens:$prompt_tokens,
                  gen_tokens:$gen_tokens,
                  batch:$batch,
                  ubatch:$ubatch,
                  status:$status,
                  raw_file:$raw_file,
                  stderr_file:$stderr_file,
                  stderr_tail:$stderr_tail,
                  llama:{}
                }' >> "$run_dir/results.jsonl"
            fi
          done
        done
      done
    done
  done
done

{
  printf 'case_id\tbinary_label\tthreads\tprompt_tokens\tgen_tokens\tbatch\tubatch\ttest\tstatus\ttokens_per_second\tt_avg_ms\tt_stddev_ms\tmodel_type\tmodel_size\traw_file\n'
  jq -r '
    [
      .case_id,
      .binary_label,
      .threads,
      .prompt_tokens,
      .gen_tokens,
      .batch,
      .ubatch,
      (.llama.test // ""),
      .status,
      (.llama.tokens_per_second // .llama.tok_per_sec // .llama.avg_ts // ""),
      (.llama.t_avg_ms // .llama.avg_ms // ""),
      (.llama.t_stddev_ms // .llama.stddev_ms // ""),
      (.llama.model_type // ""),
      (.llama.model_size // .llama.model_size_bytes // ""),
      .raw_file
    ] | @tsv
  ' "$run_dir/results.jsonl"
} > "$run_dir/summary.tsv"

jq -s '
  def avg: if length == 0 then null else add / length end;
  def tps: .llama.tokens_per_second // .llama.tok_per_sec // .llama.avg_ts // null;
  map(select(.status == "ok" and (tps != null)))
  | sort_by(.binary_label, .threads, .prompt_tokens, .gen_tokens, .batch, .ubatch, (.llama.test // ""))
  | group_by([.binary_label, .threads, .prompt_tokens, .gen_tokens, .batch, .ubatch, (.llama.test // "")])
  | map({
      binary_label: .[0].binary_label,
      threads: .[0].threads,
      prompt_tokens: .[0].prompt_tokens,
      gen_tokens: .[0].gen_tokens,
      batch: .[0].batch,
      ubatch: .[0].ubatch,
      test: (.[0].llama.test // ""),
      n: length,
      avg_tokens_per_second: (map(tps) | avg),
      min_tokens_per_second: (map(tps) | min),
      max_tokens_per_second: (map(tps) | max)
    })
' "$run_dir/results.jsonl" > "$run_dir/aggregate.json"

{
  printf 'binary_label\tthreads\tprompt_tokens\tgen_tokens\tbatch\tubatch\ttest\tn\tavg_tokens_per_second\tmin_tokens_per_second\tmax_tokens_per_second\n'
  jq -r '.[] | [.binary_label, .threads, .prompt_tokens, .gen_tokens, .batch, .ubatch, .test, .n, .avg_tokens_per_second, .min_tokens_per_second, .max_tokens_per_second] | @tsv' \
    "$run_dir/aggregate.json"
} > "$run_dir/aggregate.tsv"

write_system_snapshot after "$run_dir/system"

printf 'wrote %s\n' "$run_dir"
printf 'summary: %s\n' "$run_dir/summary.tsv"
printf 'aggregate: %s\n' "$run_dir/aggregate.tsv"
