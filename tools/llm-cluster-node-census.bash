#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  llm-cluster-node-census.bash --target HOST [options]

Collect one live-node census record for the LLM cluster pilot. This is meant
for the pre-switch direct-link phase: boot one Yoga, run llm-cluster-ip, then
capture comparable inventory and optional iperf3 results.

Options:
  --target HOST            required node address or name
  --user USER              SSH user for the live node; default: root
  --jump HOST              optional SSH ProxyJump, e.g. trajanus
  --label NAME             run label; default: node
  --out-root DIR           output parent; default: /tmp/llm-cluster-census
  --iperf-client-host HOST host that can run iperf3 toward target
  --iperf-client-bin PATH  iperf3 path on client host; auto-detected by default
  --duration SEC           iperf3 duration; default: 10
  --port N                 iperf3 port; default: 5201
  --skip-iperf             inventory only
  --left-usb-a-state TEXT  observed left USB-A state/test result
  --right-usb-a-state TEXT observed right USB-A state/test result
  --usb-a-note TEXT        observed USB-A port state
  --computrace-warning S   observed BIOS Computrace warning: absent/present/unknown
  --secure-boot-state S    observed Secure Boot state/action
  --windows-sale-ready S   whether Windows is ready for resale: yes/no/unknown
  --cleaned-state S        whether the unit has been physically cleaned: yes/no/unknown
  --network-note TEXT      network context note
  --note TEXT              extra operator note; may be repeated
  -h, --help               show this help

Example:
  tools/llm-cluster-node-census.bash \
    --target 10.42.0.11 \
    --jump trajanus \
    --iperf-client-host trajanus \
    --label x1-yoga-gen5 \
    --usb-a-note 'right USB-A not working' \
    --computrace-warning absent
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
  value="${value//[^A-Za-z0-9_.-]/_}"
  printf '%s' "$value"
}

tsv_value() {
  local value="$1"
  value="${value//$'\t'/ }"
  value="${value//$'\n'/ }"
  value="${value//$'\r'/ }"
  printf '%s' "$value"
}

join_notes() {
  local joined=""
  local note
  for note in "$@"; do
    if [[ -n "$joined" ]]; then
      joined+="; "
    fi
    joined+="$note"
  done
  printf '%s' "$joined"
}

target_ssh() {
  local script="$1"
  # shellcheck disable=SC2029
  ssh "${target_ssh_opts[@]}" "$ssh_user@$target" \
    "bash -lc $(printf '%q' "$script")"
}

client_ssh() {
  local script="$1"
  # shellcheck disable=SC2029
  ssh "${client_ssh_opts[@]}" "$iperf_client_host" \
    "bash -lc $(printf '%q' "$script")"
}

target=
ssh_user=root
ssh_jump=
label=node
out_root=/tmp/llm-cluster-census
iperf_client_host=
iperf_client_bin=
duration=10
port=5201
skip_iperf=false
left_usb_a_state=
right_usb_a_state=
usb_a_note=
computrace_warning=unknown
secure_boot_state=disabled_for_live_boot_reenable_before_sale
windows_sale_ready=unknown
cleaned_state=unknown
network_note="direct-link over current gigabit USB Ethernet adapter; not the ordered RTL8156B 2.5GbE adapters"
notes=()

while (($# > 0)); do
  case "$1" in
    --target) target="$2"; shift 2 ;;
    --target=*) target="${1#*=}"; shift ;;
    --user) ssh_user="$2"; shift 2 ;;
    --user=*) ssh_user="${1#*=}"; shift ;;
    --jump) ssh_jump="$2"; shift 2 ;;
    --jump=*) ssh_jump="${1#*=}"; shift ;;
    --label) label="$2"; shift 2 ;;
    --label=*) label="${1#*=}"; shift ;;
    --out-root) out_root="$2"; shift 2 ;;
    --out-root=*) out_root="${1#*=}"; shift ;;
    --iperf-client-host) iperf_client_host="$2"; shift 2 ;;
    --iperf-client-host=*) iperf_client_host="${1#*=}"; shift ;;
    --iperf-client-bin) iperf_client_bin="$2"; shift 2 ;;
    --iperf-client-bin=*) iperf_client_bin="${1#*=}"; shift ;;
    --duration) duration="$2"; shift 2 ;;
    --duration=*) duration="${1#*=}"; shift ;;
    --port) port="$2"; shift 2 ;;
    --port=*) port="${1#*=}"; shift ;;
    --skip-iperf) skip_iperf=true; shift ;;
    --left-usb-a-state) left_usb_a_state="$2"; shift 2 ;;
    --left-usb-a-state=*) left_usb_a_state="${1#*=}"; shift ;;
    --right-usb-a-state) right_usb_a_state="$2"; shift 2 ;;
    --right-usb-a-state=*) right_usb_a_state="${1#*=}"; shift ;;
    --usb-a-note) usb_a_note="$2"; shift 2 ;;
    --usb-a-note=*) usb_a_note="${1#*=}"; shift ;;
    --computrace-warning) computrace_warning="$2"; shift 2 ;;
    --computrace-warning=*) computrace_warning="${1#*=}"; shift ;;
    --secure-boot-state) secure_boot_state="$2"; shift 2 ;;
    --secure-boot-state=*) secure_boot_state="${1#*=}"; shift ;;
    --windows-sale-ready) windows_sale_ready="$2"; shift 2 ;;
    --windows-sale-ready=*) windows_sale_ready="${1#*=}"; shift ;;
    --cleaned-state) cleaned_state="$2"; shift 2 ;;
    --cleaned-state=*) cleaned_state="${1#*=}"; shift ;;
    --network-note) network_note="$2"; shift 2 ;;
    --network-note=*) network_note="${1#*=}"; shift ;;
    --note) notes+=("$2"); shift 2 ;;
    --note=*) notes+=("${1#*=}"); shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$target" ]] || die "--target is required"
[[ "$duration" =~ ^[0-9]+$ && "$duration" -gt 0 ]] || die "--duration must be a positive integer"
[[ "$port" =~ ^[0-9]+$ && "$port" -gt 0 && "$port" -le 65535 ]] || die "--port must be between 1 and 65535"
[[ "$label" =~ ^[A-Za-z0-9_.-]+$ ]] || die "--label may only contain letters, numbers, dot, underscore, and dash"
[[ "$computrace_warning" =~ ^[A-Za-z0-9_.-]+$ ]] || die "--computrace-warning may only contain letters, numbers, dot, underscore, and dash"
[[ "$secure_boot_state" =~ ^[A-Za-z0-9_.-]+$ ]] || die "--secure-boot-state may only contain letters, numbers, dot, underscore, and dash"
[[ "$windows_sale_ready" =~ ^[A-Za-z0-9_.-]+$ ]] || die "--windows-sale-ready may only contain letters, numbers, dot, underscore, and dash"
[[ "$cleaned_state" =~ ^[A-Za-z0-9_.-]+$ ]] || die "--cleaned-state may only contain letters, numbers, dot, underscore, and dash"

require_local ssh date mkdir awk sed

target_ssh_opts=(
  -o BatchMode=yes
  -o ConnectTimeout=8
  -o ServerAliveInterval=5
  -o ServerAliveCountMax=2
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
)
if [[ -n "$ssh_jump" ]]; then
  target_ssh_opts+=(-J "$ssh_jump")
fi

client_ssh_opts=(
  -o BatchMode=yes
  -o ConnectTimeout=8
  -o ServerAliveInterval=5
  -o ServerAliveCountMax=2
)

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
run_dir="$out_root/$timestamp-$(safe_name "$label")-$(safe_name "$target")"
mkdir -p "$run_dir"

cat > "$run_dir/manifest.env" <<EOF
timestamp=$timestamp
label=$label
target=$target
ssh_user=$ssh_user
ssh_jump=$ssh_jump
iperf_client_host=$iperf_client_host
duration=$duration
port=$port
EOF

{
  printf 'key\tvalue\n'
  printf 'left_usb_a_state\t%s\n' "$(tsv_value "$left_usb_a_state")"
  printf 'right_usb_a_state\t%s\n' "$(tsv_value "$right_usb_a_state")"
  printf 'usb_a_note\t%s\n' "$(tsv_value "$usb_a_note")"
  printf 'computrace_warning\t%s\n' "$(tsv_value "$computrace_warning")"
  printf 'secure_boot_state\t%s\n' "$(tsv_value "$secure_boot_state")"
  printf 'windows_sale_ready\t%s\n' "$(tsv_value "$windows_sale_ready")"
  printf 'cleaned_state\t%s\n' "$(tsv_value "$cleaned_state")"
  printf 'network_note\t%s\n' "$(tsv_value "$network_note")"
  if ((${#notes[@]} > 0)); then
    printf 'notes\t%s\n' "$(tsv_value "$(join_notes "${notes[@]}")")"
  else
    printf 'notes\t\n'
  fi
} > "$run_dir/operator-notes.tsv"

# shellcheck disable=SC2016
inventory_script='
set -euo pipefail

section() {
  printf "\n### %s\n" "$1"
}

section identity
hostname
cat /etc/os-release 2>/dev/null || true

section chassis
for path in \
  /sys/class/dmi/id/product_name \
  /sys/class/dmi/id/product_version \
  /sys/class/dmi/id/product_serial \
  /sys/class/dmi/id/sys_vendor \
  /sys/class/dmi/id/bios_version \
  /sys/class/dmi/id/board_name \
  /sys/class/dmi/id/board_serial \
  /sys/class/dmi/id/chassis_serial; do
  if [[ -r "$path" ]]; then
    printf "%s=%s\n" "${path##*/}" "$(cat "$path")"
  fi
done

section commands
for cmd in ip ethtool iperf3 lscpu free lsusb sensors tlp-stat dmidecode; do
  if command -v "$cmd" >/dev/null 2>&1; then
    printf "%s=%s\n" "$cmd" "$(command -v "$cmd")"
  else
    printf "%s=\n" "$cmd"
  fi
done

section addresses
ip -brief addr 2>/dev/null || true

section links
ip -brief link 2>/dev/null || true

section ethtool
for iface in /sys/class/net/*; do
  iface="${iface##*/}"
  case "$iface" in lo|wl*|ww*|docker*|br-*|virbr*|tailscale*|zt*|ip6tnl*) continue ;; esac
  [[ "$(cat "/sys/class/net/$iface/type" 2>/dev/null || true)" == 1 ]] || continue
  echo "## $iface"
  ethtool "$iface" 2>/dev/null || true
done

section cpu
lscpu 2>/dev/null || true

section memory
free -h 2>/dev/null || true

section dmi_memory
if command -v dmidecode >/dev/null 2>&1; then
  dmidecode -t memory 2>/dev/null || true
fi

section usb
lsusb 2>/dev/null || true

section usb_tree
lsusb -t 2>/dev/null || true

section tlp_battery
tlp-stat -b 2>/dev/null || true

section tlp_power
tlp-stat -p 2>/dev/null || true

section sensors
sensors 2>/dev/null || true

section r8152_logs
journalctl -k -b --no-pager 2>/dev/null | grep -Ei "r8152|rtl815|usb.*eth|enx|enp.*u" | tail -n 120 || true
'

target_ssh "$inventory_script" > "$run_dir/inventory.txt"

# shellcheck disable=SC2016
summary_script='
set -euo pipefail

hostname_value="$(hostname 2>/dev/null || true)"
product="$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)"
product_version="$(cat /sys/class/dmi/id/product_version 2>/dev/null || true)"
product_serial="$(cat /sys/class/dmi/id/product_serial 2>/dev/null || true)"
board_serial="$(cat /sys/class/dmi/id/board_serial 2>/dev/null || true)"
chassis_serial="$(cat /sys/class/dmi/id/chassis_serial 2>/dev/null || true)"
bios="$(cat /sys/class/dmi/id/bios_version 2>/dev/null || true)"
cpu="$(lscpu 2>/dev/null | awk -F: "/^Model name:/ { sub(/^[ \t]+/, \"\", \$2); print \$2; exit }")"
cpus="$(lscpu 2>/dev/null | awk -F: "/^CPU\\(s\\):/ { sub(/^[ \t]+/, \"\", \$2); print \$2; exit }")"
cores="$(lscpu 2>/dev/null | awk -F: "/^Core\\(s\\) per socket:/ { sub(/^[ \t]+/, \"\", \$2); print \$2; exit }")"
threads_per_core="$(lscpu 2>/dev/null | awk -F: "/^Thread\\(s\\) per core:/ { sub(/^[ \t]+/, \"\", \$2); print \$2; exit }")"
mem_mib="$(awk "/MemTotal:/ { printf \"%.0f\", \$2 / 1024 }" /proc/meminfo 2>/dev/null || true)"
battery_cycle="$(cat /sys/class/power_supply/BAT0/cycle_count 2>/dev/null || true)"
battery_charge="$(cat /sys/class/power_supply/BAT0/capacity 2>/dev/null || true)"
battery_status="$(cat /sys/class/power_supply/BAT0/status 2>/dev/null || true)"
battery_full_design="$(cat /sys/class/power_supply/BAT0/energy_full_design 2>/dev/null || true)"
battery_full="$(cat /sys/class/power_supply/BAT0/energy_full 2>/dev/null || true)"
battery_health=""
if [[ -n "$battery_full_design" && -n "$battery_full" && "$battery_full_design" -gt 0 ]]; then
  battery_health="$(awk -v full="$battery_full" -v design="$battery_full_design" "BEGIN { printf \"%.1f\", full * 100 / design }")"
fi
link_summary="$(for iface in /sys/class/net/*; do iface="${iface##*/}"; case "$iface" in lo|wl*|ww*|docker*|br-*|virbr*|tailscale*|zt*|ip6tnl*) continue ;; esac; [[ "$(cat "/sys/class/net/$iface/type" 2>/dev/null || true)" == 1 ]] || continue; speed="$(cat /sys/class/net/$iface/speed 2>/dev/null || true)"; oper="$(cat /sys/class/net/$iface/operstate 2>/dev/null || true)"; printf "%s:%s:%s " "$iface" "$oper" "$speed"; done)"

printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
  "$hostname_value" "$product" "$product_version" "$product_serial" "$board_serial" "$chassis_serial" "$bios" "$cpu" "$cpus" "$cores" "$threads_per_core" "$mem_mib" \
  "$battery_cycle" "$battery_charge" "$battery_status" "$battery_health" "$link_summary" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
'

{
  printf 'hostname\tproduct\tproduct_version\tproduct_serial\tboard_serial\tchassis_serial\tbios\tcpu\tcpus\tcores\tthreads_per_core\tmem_mib\tbattery_cycle\tbattery_charge_pct\tbattery_status\tbattery_health_pct\tlinks\tcollected_at\tleft_usb_a_state\tright_usb_a_state\tusb_a_note\tcomputrace_warning\tsecure_boot_state\twindows_sale_ready\tcleaned_state\tnetwork_note\tnotes\n'
  summary_row="$(target_ssh "$summary_script")"
  joined_notes=""
  if ((${#notes[@]} > 0)); then
    joined_notes="$(join_notes "${notes[@]}")"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$summary_row" \
    "$(tsv_value "$left_usb_a_state")" \
    "$(tsv_value "$right_usb_a_state")" \
    "$(tsv_value "$usb_a_note")" \
    "$(tsv_value "$computrace_warning")" \
    "$(tsv_value "$secure_boot_state")" \
    "$(tsv_value "$windows_sale_ready")" \
    "$(tsv_value "$cleaned_state")" \
    "$(tsv_value "$network_note")" \
    "$(tsv_value "$joined_notes")"
} > "$run_dir/summary.tsv"

if [[ "$skip_iperf" != true ]]; then
  [[ -n "$iperf_client_host" ]] || die "--iperf-client-host is required unless --skip-iperf is set"

  target_ssh "
set -euo pipefail
if [ -f /tmp/llm-iperf3.pid ] && kill -0 \"\$(cat /tmp/llm-iperf3.pid)\" 2>/dev/null; then
  :
else
  iperf3 -s -D --pidfile /tmp/llm-iperf3.pid --port $port
fi
cat /tmp/llm-iperf3.pid
" > "$run_dir/iperf-server.pid"

  if [[ -z "$iperf_client_bin" ]]; then
    iperf_client_bin="$(
      client_ssh 'command -v iperf3 2>/dev/null || ls -d /nix/store/*-iperf-*/bin/iperf3 2>/dev/null | tail -n 1'
    )"
  fi
  [[ -n "$iperf_client_bin" ]] || die "could not find iperf3 on $iperf_client_host"
  printf '%s\n' "$iperf_client_bin" > "$run_dir/iperf-client-bin.txt"

  client_ssh "$(printf '%q' "$iperf_client_bin") -c $(printf '%q' "$target") -t $duration --port $port" \
    > "$run_dir/iperf-forward.txt"
  client_ssh "$(printf '%q' "$iperf_client_bin") -c $(printf '%q' "$target") -t $duration --port $port -R" \
    > "$run_dir/iperf-reverse.txt"

  {
    printf "direction\tbitrate_mbits_per_sec\tretransmits\n"
    awk -v direction=forward '
      /sender$/ {
        bitrate = $(NF-3)
        unit = $(NF-2)
        retransmits = $(NF-1)
        if (unit == "Gbits/sec") bitrate *= 1000
        if (unit == "Kbits/sec") bitrate /= 1000
        printf "%s\t%s\t%s\n", direction, bitrate, retransmits
      }
    ' "$run_dir/iperf-forward.txt"
    awk -v direction=reverse '
      /sender$/ {
        bitrate = $(NF-3)
        unit = $(NF-2)
        retransmits = $(NF-1)
        if (unit == "Gbits/sec") bitrate *= 1000
        if (unit == "Kbits/sec") bitrate /= 1000
        printf "%s\t%s\t%s\n", direction, bitrate, retransmits
      }
    ' "$run_dir/iperf-reverse.txt"
  } > "$run_dir/iperf-summary.tsv"
fi

printf '%s\n' "$run_dir"
