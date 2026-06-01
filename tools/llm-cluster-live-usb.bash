#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  llm-cluster-live-usb.bash [global options] COMMAND [command options]

Prepare a USB stick for the disposable LLM cluster live image.

Global options:
  --remote HOST      SSH host with the GC-rooted ISO; default: trajanus
  --root PATH        remote GC root; default: /root/llm-cluster-live-iso
  --ssh-option OPT   extra ssh option; may be repeated
  -h, --help         show this help

Commands:
  remote-path        print the ISO path on the remote host
  remote-list        list likely USB/removable disks on the remote host
  remote-flash       write the remote ISO to a remote whole disk; requires --yes
  fetch [DESTDIR]    copy the ISO from the remote host; default: $TMPDIR or /tmp
  list               list likely USB/removable disks on this machine
  flash              write an ISO to a whole disk; requires --yes

Flash options:
  --iso PATH         local ISO path to write
  --disk DEVICE      whole disk device, for example /dev/disk4 or /dev/sdb
  --yes              required acknowledgement that DEVICE will be erased
  --eject            eject or power off the USB after a verified remote flash

Examples:
  tools/llm-cluster-live-usb.bash remote-path
  tools/llm-cluster-live-usb.bash remote-list
  tools/llm-cluster-live-usb.bash remote-flash --disk /dev/sda --yes --eject
  tools/llm-cluster-live-usb.bash fetch /tmp
  tools/llm-cluster-live-usb.bash list
  tools/llm-cluster-live-usb.bash flash \
    --iso /tmp/llm-cluster-live-26.05.20260505.549bd84-x86_64-linux.iso \
    --disk /dev/disk4 \
    --yes
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  local missing=()
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  ((${#missing[@]} == 0)) || die "missing command(s): ${missing[*]}"
}

remote=trajanus
remote_root=/root/llm-cluster-live-iso
ssh_opts=(
  -o BatchMode=yes
  -o ConnectTimeout=8
)

while (($# > 0)); do
  case "$1" in
    --remote) remote="$2"; shift 2 ;;
    --remote=*) remote="${1#*=}"; shift ;;
    --root) remote_root="$2"; shift 2 ;;
    --root=*) remote_root="${1#*=}"; shift ;;
    --ssh-option) ssh_opts+=("-o" "$2"); shift 2 ;;
    --ssh-option=*) ssh_opts+=("-o" "${1#*=}"); shift ;;
    -h|--help) usage; exit 0 ;;
    remote-path|remote-list|remote-flash|fetch|list|flash) command_name="$1"; shift; break ;;
    *) die "unknown argument: $1" ;;
  esac
done

command_name="${command_name:-}"
[[ -n "$command_name" ]] || die "missing COMMAND; run --help"

remote_iso_path() {
  require_cmd ssh
  local remote_iso_dir
  remote_iso_dir="$(printf '%q' "$remote_root/iso")"
  # shellcheck disable=SC2029
  ssh "${ssh_opts[@]}" "$remote" \
    "find -L $remote_iso_dir -maxdepth 1 -type f -name '*.iso' -print -quit"
}

list_disks() {
  case "$(uname -s)" in
    Darwin)
      require_cmd diskutil
      diskutil list external physical
      ;;
    Linux)
      require_cmd lsblk
      lsblk -o NAME,SIZE,MODEL,SERIAL,TRAN,RM,TYPE,MOUNTPOINTS
      ;;
    *)
      die "unsupported OS for disk listing: $(uname -s)"
      ;;
  esac
}

remote_list_disks() {
  require_cmd ssh
  ssh "${ssh_opts[@]}" "$remote" \
    "lsblk -o NAME,PATH,SIZE,MODEL,SERIAL,TRAN,RM,RO,TYPE,MOUNTPOINTS"
}

remote_flash_iso() {
  local disk=
  local yes=false
  local eject=false

  while (($# > 0)); do
    case "$1" in
      --disk) disk="$2"; shift 2 ;;
      --disk=*) disk="${1#*=}"; shift ;;
      --yes) yes=true; shift ;;
      --eject) eject=true; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown remote-flash argument: $1" ;;
    esac
  done

  [[ -n "$disk" ]] || die "remote-flash requires --disk DEVICE"
  [[ "$yes" == true ]] || die "refusing to erase a disk without --yes"

  require_cmd ssh
  ssh "${ssh_opts[@]}" "$remote" bash -s -- "$remote_root" "$disk" "$eject" <<'REMOTE_FLASH'
set -euo pipefail

remote_root="$1"
disk="$2"
eject_after="$3"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

command -v lsblk >/dev/null || die "missing command: lsblk"
command -v dd >/dev/null || die "missing command: dd"
command -v cmp >/dev/null || die "missing command: cmp"
command -v stat >/dev/null || die "missing command: stat"
command -v findmnt >/dev/null || die "missing command: findmnt"

[[ "$disk" == /dev/* ]] || die "pass a whole device path under /dev"
[[ -b "$disk" ]] || die "not a block device: $disk"

iso="$(find -L "$remote_root/iso" -maxdepth 1 -type f -name '*.iso' -print -quit)"
[[ -n "$iso" ]] || die "no ISO found under $remote_root/iso"
[[ -f "$iso" ]] || die "ISO not found: $iso"

read -r tran rm ro type < <(lsblk -dn -o TRAN,RM,RO,TYPE "$disk")
[[ "$type" == "disk" ]] || die "refusing to write non-disk device: $disk"
[[ "$ro" == "0" ]] || die "refusing to write read-only device: $disk"
if [[ "$tran" != "usb" && "$rm" != "1" ]]; then
  die "refusing to write non-USB/non-removable device: $disk"
fi

root_source="$(findmnt -n -o SOURCE / || true)"
if [[ -n "$root_source" && "$root_source" == "$disk"* ]]; then
  die "refusing to write root device: $disk"
fi

printf 'About to erase and write on %s:\n' "$(hostname)"
printf '  ISO:  %s\n' "$iso"
printf '  Disk: %s\n\n' "$disk"
lsblk -o NAME,PATH,SIZE,MODEL,SERIAL,TRAN,RM,RO,TYPE,MOUNTPOINTS "$disk"

size="$(stat -c %s "$iso")"
if cmp -n "$size" "$iso" "$disk" >/dev/null 2>&1; then
  printf '\nUSB already matches the ISO; skipping write.\n'
else
  while read -r partition; do
    [[ -n "$partition" ]] || continue
    umount "$partition" 2>/dev/null || true
  done < <(lsblk -ln -o PATH "$disk" | tail -n +2)

  dd if="$iso" of="$disk" bs=16M status=progress conv=fsync
  sync
  blockdev --rereadpt "$disk" 2>/dev/null || true
fi

cmp -n "$size" "$iso" "$disk"
printf 'usb-verified\n'

if [[ "$eject_after" == "true" ]]; then
  sync
  eject "$disk" 2>/dev/null || udisksctl power-off -b "$disk" 2>/dev/null || true
fi
REMOTE_FLASH
}

flash_darwin() {
  local iso="$1"
  local disk="$2"

  require_cmd diskutil sudo dd sync
  [[ "$disk" =~ ^/dev/disk[0-9]+$ ]] || die "on macOS, pass a whole disk like /dev/disk4"
  diskutil info "$disk" >/dev/null
  diskutil info "$disk" | awk -F: '
    /^ *Device Location:/ {
      gsub(/^[ \t]+|[ \t]+$/, "", $2)
      if ($2 == "External") found = 1
    }
    END { exit found ? 0 : 1 }
  ' || die "refusing to write non-external disk: $disk"

  local raw_disk="/dev/r${disk#/dev/}"

  printf 'About to erase and write:\n'
  printf '  ISO:  %s\n' "$iso"
  printf '  Disk: %s\n\n' "$disk"
  diskutil info "$disk"

  diskutil unmountDisk "$disk"
  sudo dd if="$iso" of="$raw_disk" bs=16m conv=sync
  sync
  diskutil eject "$disk" || true
}

flash_linux() {
  local iso="$1"
  local disk="$2"

  require_cmd lsblk sudo dd sync findmnt
  [[ -b "$disk" ]] || die "not a block device: $disk"

  local root_source
  root_source="$(findmnt -n -o SOURCE / || true)"
  if [[ -n "$root_source" && "$root_source" == "$disk"* ]]; then
    die "refusing to write the root device: $disk"
  fi

  printf 'About to erase and write:\n'
  printf '  ISO:  %s\n' "$iso"
  printf '  Disk: %s\n\n' "$disk"
  lsblk "$disk"

  local partition
  while read -r partition; do
    [[ -n "$partition" ]] || continue
    sudo umount "$partition" 2>/dev/null || true
  done < <(lsblk -ln -o PATH "$disk" | tail -n +2)

  sudo dd if="$iso" of="$disk" bs=16M status=progress conv=fsync
  sync
}

flash_iso() {
  local iso=
  local disk=
  local yes=false

  while (($# > 0)); do
    case "$1" in
      --iso) iso="$2"; shift 2 ;;
      --iso=*) iso="${1#*=}"; shift ;;
      --disk) disk="$2"; shift 2 ;;
      --disk=*) disk="${1#*=}"; shift ;;
      --yes) yes=true; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown flash argument: $1" ;;
    esac
  done

  [[ -n "$iso" ]] || die "flash requires --iso PATH"
  [[ -n "$disk" ]] || die "flash requires --disk DEVICE"
  [[ -f "$iso" ]] || die "ISO not found: $iso"
  [[ "$yes" == true ]] || die "refusing to erase a disk without --yes"

  case "$(uname -s)" in
    Darwin) flash_darwin "$iso" "$disk" ;;
    Linux) flash_linux "$iso" "$disk" ;;
    *) die "unsupported OS for flashing: $(uname -s)" ;;
  esac
}

case "$command_name" in
  remote-path)
    remote_iso_path
    ;;
  remote-list)
    (($# == 0)) || die "remote-list does not accept arguments"
    remote_list_disks
    ;;
  remote-flash)
    remote_flash_iso "$@"
    ;;
  fetch)
    require_cmd scp mkdir basename
    if (($# > 0)); then
      dest_dir="$1"
      shift
    else
      dest_dir="${TMPDIR:-/tmp}"
    fi
    (($# == 0)) || die "fetch accepts at most one DESTDIR"
    mkdir -p "$dest_dir"
    iso_path="$(remote_iso_path)"
    [[ -n "$iso_path" ]] || die "no ISO found under $remote:$remote_root/iso"
    iso_name="$(basename "$iso_path")"
    scp -p "$remote:$iso_path" "$dest_dir/$iso_name"
    printf '%s\n' "$dest_dir/$iso_name"
    ;;
  list)
    (($# == 0)) || die "list does not accept arguments"
    list_disks
    ;;
  flash)
    flash_iso "$@"
    ;;
  *)
    die "unknown command: $command_name"
    ;;
esac
