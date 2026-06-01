#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  llm-cluster-fabric.bash --targets HOST[,HOST...] [options]

Collect a first-pass network fabric run for the cheap-laptop LLM cluster pilot.
The script SSHes into each target, captures basic host/NIC inventory, starts
iperf3 servers, then runs ping and one-way iperf3 tests for each ordered pair.
It writes raw per-pair output plus small TSV summaries for quick graphing.

Targets should be names or IPs reachable by every other target over the lab
fabric. If SSH needs a user, pass --user USER or include user@host entries.

Options:
  --targets CSV       required target list
  --user USER         SSH user for targets that do not already include user@
  --duration SEC      iperf3 duration per pair; default: 10
  --parallel N        iperf3 parallel streams; default: 1
  --ping-count N      ping packets per pair; default: 20
  --port N            iperf3 server port; default: 5201
  --out-root DIR      output parent; default: /tmp/llm-cluster-fabric
  --label NAME        run directory label; default: fabric
  --ssh-option OPT    extra ssh option; may be repeated
  --skip-iperf        capture inventory and ping only
  --skip-ping         capture inventory and iperf only
  -h, --help          show this help

Example:
  tools/llm-cluster-fabric.bash \
    --targets trajanus,llm-yoga-01,llm-yoga-02,llm-yoga-03 \
    --duration 15
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_local() {
  local missing=()
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  ((${#missing[@]} == 0)) || die "missing local command(s): ${missing[*]}"
}

safe_name() {
  local value="$1"
  value="${value#*@}"
  value="${value//[^A-Za-z0-9_.-]/_}"
  printf '%s' "$value"
}

target_ref() {
  local target="$1"
  if [[ -n "$ssh_user" && "$target" != *@* ]]; then
    printf '%s@%s' "$ssh_user" "$target"
  else
    printf '%s' "$target"
  fi
}

target_host() {
  local target="$1"
  target="${target#*@}"
  target="${target%%:*}"
  printf '%s' "$target"
}

remote_bash() {
  local target="$1"
  local script="$2"
  # shellcheck disable=SC2029
  ssh "${ssh_base_opts[@]}" "${ssh_extra_opts[@]}" "$(target_ref "$target")" \
    "bash -lc $(printf '%q' "$script")"
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

write_ping_summary_row() {
  local src="$1"
  local dst="$2"
  local status="$3"
  local file="$4"

  if [[ "$status" != ok ]]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$src" "$dst" "$status" "" "" "" "" "" "" ""
    return 0
  fi

  awk -v src="$src" -v dst="$dst" -v status="$status" '
    /packets transmitted/ {
      transmitted = $1
      received = $4
      loss = $6
    }
    /^(rtt|round-trip) min\/avg\/max/ {
      split($4, values, "/")
      min = values[1]
      avg = values[2]
      max = values[3]
      mdev = values[4]
    }
    END {
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n",
        src, dst, status, transmitted, received, loss, min, avg, max, mdev
    }
  ' "$file"
}

write_iperf_summary_row() {
  local src="$1"
  local dst="$2"
  local status="$3"
  local file="$4"

  if [[ "$status" != ok ]]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$src" "$dst" "$status" "" "" "" "" "" "" "" "" "" ""
    return 0
  fi

  jq -r --arg src "$src" --arg dst "$dst" --arg status "$status" '
    .end.sum_sent as $sent
    | .end.sum_received as $received
    | .end.cpu_utilization_percent as $cpu
    | [
        $src,
        $dst,
        $status,
        ($sent.seconds // ""),
        ($sent.bytes // ""),
        ($sent.bits_per_second // ""),
        (if $sent.bits_per_second then ($sent.bits_per_second / 1000000000) else "" end),
        ($sent.retransmits // ""),
        ($received.bytes // ""),
        ($received.bits_per_second // ""),
        (if $received.bits_per_second then ($received.bits_per_second / 1000000000) else "" end),
        ($cpu.host_total // ""),
        ($cpu.remote_total // "")
      ]
    | @tsv
  ' "$file"
}

targets_csv=
ssh_user=
duration=10
parallel=1
ping_count=20
port=5201
out_root=/tmp/llm-cluster-fabric
label=fabric
skip_iperf=false
skip_ping=false
ssh_extra_opts=()
ssh_base_opts=(
  -o BatchMode=yes
  -o ConnectTimeout=8
  -o ServerAliveInterval=5
  -o ServerAliveCountMax=2
)

while (($# > 0)); do
  case "$1" in
    --targets) targets_csv="$2"; shift 2 ;;
    --targets=*) targets_csv="${1#*=}"; shift ;;
    --user) ssh_user="$2"; shift 2 ;;
    --user=*) ssh_user="${1#*=}"; shift ;;
    --duration) duration="$2"; shift 2 ;;
    --duration=*) duration="${1#*=}"; shift ;;
    --parallel) parallel="$2"; shift 2 ;;
    --parallel=*) parallel="${1#*=}"; shift ;;
    --ping-count) ping_count="$2"; shift 2 ;;
    --ping-count=*) ping_count="${1#*=}"; shift ;;
    --port) port="$2"; shift 2 ;;
    --port=*) port="${1#*=}"; shift ;;
    --out-root) out_root="$2"; shift 2 ;;
    --out-root=*) out_root="${1#*=}"; shift ;;
    --label) label="$2"; shift 2 ;;
    --label=*) label="${1#*=}"; shift ;;
    --ssh-option) ssh_extra_opts+=("-o" "$2"); shift 2 ;;
    --ssh-option=*) ssh_extra_opts+=("-o" "${1#*=}"); shift ;;
    --skip-iperf) skip_iperf=true; shift ;;
    --skip-ping) skip_ping=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$targets_csv" ]] || die "--targets is required"
[[ "$duration" =~ ^[0-9]+$ && "$duration" -gt 0 ]] || die "--duration must be a positive integer"
[[ "$parallel" =~ ^[0-9]+$ && "$parallel" -gt 0 ]] || die "--parallel must be a positive integer"
[[ "$ping_count" =~ ^[0-9]+$ && "$ping_count" -gt 0 ]] || die "--ping-count must be a positive integer"
[[ "$port" =~ ^[0-9]+$ && "$port" -gt 0 && "$port" -le 65535 ]] || die "--port must be between 1 and 65535"
[[ "$label" =~ ^[A-Za-z0-9_.-]+$ ]] || die "--label may only contain letters, numbers, dot, underscore, and dash"

require_local ssh date mkdir awk
if [[ "$skip_iperf" != true ]]; then
  require_local jq
fi

declare -a targets
csv_to_array "$targets_csv" targets
((${#targets[@]} >= 2)) || die "at least two targets are required"

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
run_dir="${out_root}/${label}-${timestamp}"
mkdir -p "$run_dir"/{targets,ping,iperf}

server_tag="llm-cluster-fabric-${timestamp}-${port}"
server_pidfile="/tmp/${server_tag}.pid"
server_log="/tmp/${server_tag}.log"
started_servers=false

cleanup_servers() {
  if [[ "$started_servers" != true ]]; then
    return 0
  fi
  local target
  local cleanup_script
  cleanup_script="
set +e
if [[ -f '$server_pidfile' ]]; then
  kill \"\$(cat '$server_pidfile')\" >/dev/null 2>&1
  rm -f '$server_pidfile'
fi
rm -f '$server_log'
"
  for target in "${targets[@]}"; do
    remote_bash "$target" "$cleanup_script" >/dev/null 2>&1 || true
  done
}
trap cleanup_servers EXIT

{
  printf 'timestamp_utc=%s\n' "$timestamp"
  printf 'targets=%s\n' "$targets_csv"
  printf 'duration=%s\n' "$duration"
  printf 'parallel=%s\n' "$parallel"
  printf 'ping_count=%s\n' "$ping_count"
  printf 'port=%s\n' "$port"
} > "$run_dir/manifest.env"

# shellcheck disable=SC2016
inventory_script='
set +e
echo "### identity"
hostname
date -Is
uname -a
echo
echo "### commands"
for cmd in ip ethtool iperf3 lscpu free lsusb sensors tlp-stat; do
  if command -v "$cmd" >/dev/null 2>&1; then
    printf "%s=%s\n" "$cmd" "$(command -v "$cmd")"
  else
    printf "%s=missing\n" "$cmd"
  fi
done
echo
echo "### cpu"
lscpu 2>/dev/null
echo
echo "### memory"
free -h 2>/dev/null
echo
echo "### usb"
lsusb 2>/dev/null
echo
echo "### links"
ip -br link 2>/dev/null
echo
echo "### addresses"
ip -br addr 2>/dev/null
echo
echo "### ethtool"
if command -v ethtool >/dev/null 2>&1; then
  for iface in /sys/class/net/*; do
    iface="${iface##*/}"
    echo "--- $iface"
    ethtool "$iface" 2>/dev/null
  done
fi
echo
echo "### sensors"
sensors 2>/dev/null
echo
echo "### tlp"
tlp-stat -s -b 2>/dev/null
'

printf 'target\tstatus\tfile\n' > "$run_dir/inventory.tsv"
for target in "${targets[@]}"; do
  safe="$(safe_name "$target")"
  inventory_file="$run_dir/targets/${safe}.txt"
  if remote_bash "$target" "$inventory_script" > "$inventory_file" 2> "$run_dir/targets/${safe}.stderr"; then
    printf '%s\tok\t%s\n' "$target" "$inventory_file" >> "$run_dir/inventory.tsv"
  else
    printf '%s\tfailed\t%s\n' "$target" "$inventory_file" >> "$run_dir/inventory.tsv"
  fi
done

if [[ "$skip_iperf" != true ]]; then
  server_script="
set -euo pipefail
command -v iperf3 >/dev/null 2>&1
if [[ -f '$server_pidfile' ]]; then
  kill \"\$(cat '$server_pidfile')\" >/dev/null 2>&1 || true
  rm -f '$server_pidfile'
fi
rm -f '$server_log'
if iperf3 --help 2>&1 | grep -q -- '--pidfile'; then
  iperf3 -s -D -p '$port' --pidfile '$server_pidfile' >'$server_log' 2>&1
else
  nohup iperf3 -s -p '$port' >'$server_log' 2>&1 &
  echo \$! > '$server_pidfile'
fi
sleep 0.3
cat '$server_pidfile'
"

  printf 'target\tstatus\tpid\n' > "$run_dir/iperf-servers.tsv"
  for target in "${targets[@]}"; do
    if pid="$(remote_bash "$target" "$server_script" 2> "$run_dir/iperf/server-$(safe_name "$target").stderr")"; then
      printf '%s\tok\t%s\n' "$target" "$pid" >> "$run_dir/iperf-servers.tsv"
    else
      printf '%s\tfailed\t\n' "$target" >> "$run_dir/iperf-servers.tsv"
      die "failed to start iperf3 server on $target"
    fi
  done
  started_servers=true
fi

printf 'source\tdestination\tping_status\tiperf_status\tping_file\tiperf_file\n' > "$run_dir/matrix.tsv"
printf 'source\tdestination\tstatus\tpackets_tx\tpackets_rx\tpacket_loss\tmin_ms\tavg_ms\tmax_ms\tmdev_or_stddev_ms\n' > "$run_dir/ping-summary.tsv"
printf 'source\tdestination\tstatus\tduration_s\tbytes_sent\tbits_per_second_sent\tgbits_per_second_sent\tretransmits\tbytes_received\tbits_per_second_received\tgbits_per_second_received\thost_cpu_pct\tremote_cpu_pct\n' > "$run_dir/iperf-summary.tsv"
for src in "${targets[@]}"; do
  for dst in "${targets[@]}"; do
    [[ "$src" != "$dst" ]] || continue

    src_safe="$(safe_name "$src")"
    dst_safe="$(safe_name "$dst")"
    dst_host="$(target_host "$dst")"
    ping_file="$run_dir/ping/${src_safe}_to_${dst_safe}.txt"
    iperf_file="$run_dir/iperf/${src_safe}_to_${dst_safe}.json"
    ping_status=skipped
    iperf_status=skipped

    if [[ "$skip_ping" != true ]]; then
      ping_cmd="ping -c '$ping_count' -i 0.2 -W 1 $(printf '%q' "$dst_host")"
      if remote_bash "$src" "$ping_cmd" > "$ping_file" 2> "${ping_file}.stderr"; then
        ping_status=ok
      else
        ping_status=failed
      fi
    fi

    if [[ "$skip_iperf" != true ]]; then
      iperf_cmd="iperf3 -J -c $(printf '%q' "$dst_host") -p '$port' -t '$duration' -P '$parallel' --get-server-output"
      if remote_bash "$src" "$iperf_cmd" > "$iperf_file" 2> "${iperf_file}.stderr"; then
        iperf_status=ok
      else
        iperf_status=failed
      fi
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$src" "$dst" "$ping_status" "$iperf_status" "$ping_file" "$iperf_file" >> "$run_dir/matrix.tsv"

    if [[ "$skip_ping" != true ]]; then
      write_ping_summary_row "$src" "$dst" "$ping_status" "$ping_file" >> "$run_dir/ping-summary.tsv"
    fi

    if [[ "$skip_iperf" != true ]]; then
      if ! write_iperf_summary_row "$src" "$dst" "$iperf_status" "$iperf_file" >> "$run_dir/iperf-summary.tsv"; then
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
          "$src" "$dst" "parse_failed" "" "" "" "" "" "" "" "" "" "" >> "$run_dir/iperf-summary.tsv"
      fi
    fi
  done
done

printf 'wrote %s\n' "$run_dir"
printf 'summary: %s\n' "$run_dir/matrix.tsv"
[[ "$skip_ping" == true ]] || printf 'summary: %s\n' "$run_dir/ping-summary.tsv"
[[ "$skip_iperf" == true ]] || printf 'summary: %s\n' "$run_dir/iperf-summary.tsv"
