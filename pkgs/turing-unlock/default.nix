# TU102 tensor-core unlock (nlzy/turing-unlock 2.0.0) for the tiberius lane.
#
# A volatile pre-driver unlock: a small GPL kernel module, loaded from the
# initramfs before nvidia can bind, runs the pinned NVIDIA Booter/ACR firmware
# against the TU102's Falcon/RM state and writes two speed selectors
# (SS0=0x88888888, SS1=0x8). The result is full-rate FP16 tensor cores
# (FMLA32) and integer IMLA4 until the next power cycle; nothing is flashed,
# no VBIOS or persistent firmware is modified, and a normal power-off restores
# the locked state.
#
# Measured on tiberius (RTX 2080 Ti 22 GB, `10de:1e04`, driver 595.71.05,
# kernel 6.18.54), 2026-11-05, same engine/config/boot, locked vs unlocked:
# prefill read P27 (26,134 tok) -5.7 % at the production 280 W cap (-6.2 % in a
# controlled 200 W pair), 8,268 tok -2.0/-2.6 %, 4,252 tok -1.1/-1.0 %; decode
# unchanged (109.4 tok/s at 280 W); greedy answer shas identical on every cell
# and both lock states. The phase attribution shows the gain in the dense/
# projection MMA phases (gdn -37 %, qsa proj -39 %, hc read -34..-65 %), with
# the MoE expert GEMMs unchanged. Upstream warns that unlocking full-rate
# tensor cores raises power draw; both measured sessions stayed inside the
# existing power cap (<=60 C, no Xid).
#
# Provenance / licensing: the module source is nlzy/turing-unlock at the pinned
# commit (GPL-2.0-only). The six firmware files are generated at build time
# from NVIDIA 610.43.03 artifacts fetched from NVIDIA/CachyOS (fixed-output
# hashes pinned below; NVIDA-licensed, never committed to this public repo) by
# the upstream GPL scripts. Kernel compatibility is checked at evaluation time:
# the module is built against the plain nixpkgs kernel for the same version as
# the booted kernel (the host's fsdax kernel patch does not change the module
# ABI; CONFIG_MODVERSIONS is off, so the vermagic is the only handshake).
#
# Safety: if the module refuses or the firmware fails to quiesce, it logs and
# the boot continues (the lane then runs locked). A failed step may need a full
# power cycle (the module retains DMA buffers until then); on this host the BMC
# can power-cycle it remotely. Enable/disable takes effect on the next boot.
{
  lib,
  stdenv,
  fetchFromGitHub,
  fetchurl,
  python3,
  zstd,
  pkgs,
}:

let
  # The plain nixpkgs kernel of the booted version: the host's fsdax kernel
  # patch does not change the module ABI, and CONFIG_MODVERSIONS is off, so the
  # vermagic is the handshake (the profile asserts the version matches).
  kernel = pkgs.linuxPackages.kernel;
  version = "2.0.0";
  nvVersion = "610.43.03";

  unlockSrc = fetchFromGitHub {
    owner = "nlzy";
    repo = "turing-unlock";
    rev = "417f333263ff169e8f449c931b70db9dfd7b8ef4";
    hash = "sha256-70oNbxh0uEDFhUWe/nx9nYG1k2jZ1T7X3FZoYevW/F8=";
  };

  # The two NVIDIA inputs the upstream firmware generator extracts from; the
  # hashes are the ones pinned in the upstream manifest.
  nvidiaSource = fetchurl {
    url = "https://download.nvidia.com/XFree86/NVIDIA-kernel-module-source/NVIDIA-kernel-module-source-${nvVersion}.tar.xz";
    hash = "sha256-fhGJI8eiPtw2EU1jJzpG4+BOmvmGlaQiA+esLf6fwdw=";
  };
  # 2026-11-23: this URL is dead (it serves a 988-byte landing page). The one file
  # it supplied, gsp_tu10x.bin, is in NVIDIA's .run with the same hash; the boot
  # assets and the v67 payload regenerate from the other pinned inputs. See
  # regenerate-firmware.sh beside this file and
  # docs/exec-plans/active/turing-unlock-assessment.md.
  nvidiaUtils = fetchurl {
    url = "https://archive.cachyos.org/archive/cachyos-v3/nvidia-utils-${nvVersion}-1-x86_64_v3.pkg.tar.zst";
    hash = "sha256-4X58ku7/oXiw/h9A6xekcJX4/Dzkp3vxFc9b1aTfhuk=";
  };

  firmwareFiles = [
    "booter_load_tu102.bin"
    "gsp_tu10x.bin"
    "gsp_boot_tu102.bin"
    "gsp_boot_desc_tu102.bin"
    "sec2_bl_tu102.bin"
    "v67-tu102-610.43.03.bin"
  ];

  # Upstream's two generators: generate_v67.py checks the pinned package and
  # payload hashes, extract_boot_assets.py checks the source archive's assets.
  firmware = stdenv.mkDerivation {
    pname = "turing-unlock-firmware";
    inherit version;
    src = unlockSrc;

    nativeBuildInputs = [
      python3
      zstd
    ];

    buildPhase = ''
      runHook preBuild
      mkdir -p assets inputs
      ln -s ${nvidiaSource} inputs/NVIDIA-kernel-module-source-${nvVersion}.tar.xz
      ln -s ${nvidiaUtils} inputs/nvidia-utils-${nvVersion}-1-x86_64_v3.pkg.tar.zst
      mkdir -p source
      tar -xf ${nvidiaSource} -C source
      python3 firmware/generate_v67.py \
        "$(realpath inputs/nvidia-utils-${nvVersion}-1-x86_64_v3.pkg.tar.zst)" assets
      python3 firmware/extract_boot_assets.py \
        source/NVIDIA-kernel-module-source-${nvVersion} assets
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      install -d $out/lib/firmware/turing-unlock/${nvVersion}
      install -m644 ${lib.concatMapStringsSep " " (f: "assets/" + f) firmwareFiles} \
        $out/lib/firmware/turing-unlock/${nvVersion}/
      install -Dm644 assets/NVIDIA-LICENSE \
        $out/share/licenses/turing-unlock-firmware/NVIDIA-LICENSE
      install -Dm644 firmware/NOTICE.md \
        $out/share/licenses/turing-unlock-firmware/NOTICE.md
      runHook postInstall
    '';

    meta = {
      description = "NVIDIA ${nvVersion} firmware images for the TU102 unlock (fetched, not redistributed)";
      license = lib.licenses.unfreeRedistributableFirmware;
      platforms = lib.platforms.linux;
    };
  };

  module = stdenv.mkDerivation {
    pname = "turing-unlock";
    inherit version;
    src = unlockSrc;

    nativeBuildInputs = kernel.moduleBuildDependencies;
    dontConfigure = true;

    buildPhase = ''
      runHook preBuild
      make -C ${kernel.dev}/lib/modules/${kernel.modDirVersion}/build \
        M=$PWD/kernel/turing_unlock modules
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      install -Dm644 kernel/turing_unlock/turing_unlock.ko \
        $out/lib/modules/${kernel.modDirVersion}/extra/turing_unlock.ko
      runHook postInstall
    '';

    meta = {
      description = "TU102 full-rate tensor-core unlock module (nlzy/turing-unlock)";
      license = lib.licenses.gpl2Only;
      platforms = lib.platforms.linux;
    };
  };
in
{
  inherit
    firmware
    module
    firmwareFiles
    nvVersion
    unlockSrc
    ;
}
