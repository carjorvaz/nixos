#!/usr/bin/env bash
# Regenerate the six TU102 unlock firmware images from NVIDIA's own artifacts.
#
# The 2026-11-23 break was the CachyOS nvidia-utils package: its archive URL began
# returning a landing page, and that package was the only source of gsp_tu10x.bin.
# NVIDIA's own installer carries the same bytes, and the v67 image is pure
# constants, so the whole set is reproducible without CachyOS. This script does
# that and refuses to write anything whose hashes do not match the set the
# deployed tiberius generations ran (see README.md).
#
#   ./regenerate-firmware.sh OUTDIR [CACHEDIR]
#
# Network: about 490 MB on a cold cache. Requires bash, curl, tar, zstd, python3
# and coreutils. Nothing here is committed to the public repository.
set -euo pipefail

out=${1:-}
if [ -z "$out" ]; then
  echo "usage: $0 OUTDIR [CACHEDIR]" >&2
  exit 2
fi
cache=${2:-$out/cache}
PY=${PYTHON:-python3}
mkdir -p "$out/firmware" "$cache"

run_name=NVIDIA-Linux-x86_64-610.43.03.run
run_url=https://us.download.nvidia.com/XFree86/Linux-x86_64/610.43.03/$run_name
run_sha=45e2d4c134a23c35e50f253a4aa63e7e5e8d17e3d185d4a07c8a58e9612ed392

kms_name=NVIDIA-kernel-module-source-610.43.03.tar.xz
kms_url=https://download.nvidia.com/XFree86/NVIDIA-kernel-module-source/$kms_name
kms_sha=7e118923c7a23edc36114d63273a46e3e04e9af98695a42203e7ac2dfe9fc1dc

nlzy_name=turing-unlock-417f333.tar.gz
nlzy_url=https://github.com/nlzy/turing-unlock/archive/417f333263ff169e8f449c931b70db9dfd7b8ef4.tar.gz
nlzy_sha=0288bf86e78ef95ee01eb9e900eb64e97cd72fa500edcc39444135f3f9bace37

expect_gsp=73065619db9ec921d19fc4e519dd04d91a9199b525eaca9b257b89fb8c5ec52c
expect_v67=b0ec90294d1de3c67e024631c0a11000f281470d76eed806fc24c66b7fd1ef41
expect_booter=51507de61777cf46f3703a084cdfa896c21f6bc0c8af8f245bd09b2e9c49bf54
expect_boot=8765694cd38beaa4e2b8b1b83a31fb7aee6cb9d8b7c6bc7a86e6d931a3a056c2
expect_boot_desc=9e7cca2cfdc5ce601b0adba39967850046108df6c2d23fff95578ca3f0ccbe01
expect_sec2=f21f1cfbb8fffa8067685314367fc4c50f3f84dd99eda7c19db4292d9269b9d9

fetch() { # url dest sha
  if [ -f "$2" ] && echo "$3  $2" | sha256sum -c --status; then
    return 0
  fi
  curl -fL --retry 3 -o "$2.part" "$1"
  mv "$2.part" "$2"
  echo "$3  $2" | sha256sum -c --status || {
    echo "hash mismatch: $2" >&2
    exit 1
  }
}

fetch "$run_url" "$cache/$run_name" "$run_sha"
fetch "$kms_url" "$cache/$kms_name" "$kms_sha"
fetch "$nlzy_url" "$cache/$nlzy_name" "$nlzy_sha"

rm -rf "$cache/run" "$cache/kms" "$cache/nlzy"
bash "$cache/$run_name" --extract-only --target "$cache/run" --no-questions >/dev/null
cp "$cache/run/firmware/gsp_tu10x.bin" "$out/firmware/gsp_tu10x.bin"
echo "$expect_gsp  $out/firmware/gsp_tu10x.bin" | sha256sum -c --status

mkdir -p "$cache/kms" "$cache/nlzy"
tar -xf "$cache/$kms_name" -C "$cache/kms"
tar -xf "$cache/$nlzy_name" -C "$cache/nlzy"
nlzy_dir=$(find "$cache/nlzy" -maxdepth 1 -type d -name 'turing-unlock-*' | head -1)
kms_dir=$(find "$cache/kms" -maxdepth 1 -type d -name 'NVIDIA-kernel-module-source-*' | head -1)

# v67 is pure constants: build_payload() needs no package input.
"$PY" - "$nlzy_dir" "$out/firmware/v67-tu102-610.43.03.bin" <<'PY'
import sys
sys.path.insert(0, sys.argv[1] + "/firmware")
import generate_v67
open(sys.argv[2], "wb").write(generate_v67.build_payload())
PY
echo "$expect_v67  $out/firmware/v67-tu102-610.43.03.bin" | sha256sum -c --status

"$PY" "$nlzy_dir/firmware/extract_boot_assets.py" "$kms_dir" "$out/firmware"

check() { echo "$2  $1" | sha256sum -c --status || { echo "hash mismatch: $1" >&2; exit 1; }; }
check "$out/firmware/booter_load_tu102.bin" "$expect_booter"
check "$out/firmware/gsp_boot_tu102.bin" "$expect_boot"
check "$out/firmware/gsp_boot_desc_tu102.bin" "$expect_boot_desc"
check "$out/firmware/sec2_bl_tu102.bin" "$expect_sec2"

( cd "$out/firmware" && sha256sum ./*.bin > ../SHA256SUMS )
echo "regenerated six images in $out/firmware (hashes match the deployed set)"
