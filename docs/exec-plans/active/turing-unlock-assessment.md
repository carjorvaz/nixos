# Turing-unlock on tiberius: tested, adopted

Status: **tested on tiberius 2026-11-05 and adopted at boot** (see
`profiles/nixos/turing-unlock.nix` / `pkgs/turing-unlock`). This record covers the two
upstream projects that motivated it, the measured effect, the safety evidence and the
conditions under which it should be disabled or reverted.

## What was evaluated

1. <https://github.com/haohervchb/Turing-unlock> - a volatile pre-OS EFI payload that
   pokes NVIDIA RM controls through direct physical DMA on one specific ASUS TU102
   card (2x FP16-in/FP32-accum MMA in its own measurements, 1.77x cuBLAS). It is not a
   general installer: its build needs private firmware inputs (the test card's FWSEC,
   a Dell A14 root-bridge PE, pinned CMP-unlock blobs), and its guards pin PCI BDF
   `0000:02:00.0`, `10de:1e07`, subsystem `1043:866a`, BAR0 `fa000000`, the original
   Alienware board and firmware bytes. tiberius (`10de:1e04`, `1043:8687`, VBIOS
   `90.02.17.40.0E`, 22 GB mod, TYAN board, systemd-boot) differs at every one of
   those layers, so this payload was **not** attempted. Its unsafe failure mode (boot
   held in UEFI, full power cycle required) also made it a poor first choice on the
   only production GPU.
2. <https://github.com/nlzy/turing-unlock> - a Linux kernel module (2.0.0, GPL-2.0)
   that runs in the initramfs before nvidia binds, executes pinned NVIDIA
   610.43.03 Booter/ACR firmware against the GPU, and writes two speed selectors
   (`SS0=0x88888888`, `SS1=0x8`) so FMLA32 and IMLA4 run at full rate until power off.
   No VBIOS flash, no persistent firmware change. This is the one that was tested.

## Measured effect (tiberius, 2026-11-05)

Same engine (gen-104 build), same run config, same boot session; locked vs unlocked;
greedy/temperature 0, thinking off; 2 fresh-engine runs per cell per state, plus
repeats. Answer shas were **identical on every cell in both states**.

| cell | locked | unlocked | delta |
|---|---|---|---|
| P1 4,252-token read | 8,604 ms / 494.2 tok/s | ~8,518 ms / ~499 tok/s | **-1.0 %** |
| P8K 8,268-token read | 10,271 ms / 805 tok/s | 10,008 ms / 826 tok/s | **-2.6 %** |
| P27 26,134-token read | 22,488 ms / 1,162 tok/s | 21,103 ms / 1,238 tok/s | **-6.2 %** |
| L-live decode (768 gen) | 90.85 tok/s | 91.05 tok/s | +0.2 % (no change) |

The controlled pair above is at 200 W for both states. At the production 280 W cap the
unlocked numbers were P1 8,495 ms (**-1.1 %**), P8K 9,870 ms (**-2.0 %**), P27
19,610 ms / 1,332.7 tok/s (**-5.7 %**), L-live 109.4 tok/s (no decode gain) - the gain
is attributable to the unlock, not to the power cap. Phase attribution: the P27 GPU
timeline fell 6.6 %, concentrated in the dense/projection FP16 MMA phases (gdn -37 %,
qsa projection -39 %, hc read -34..-65 %), while the quantized MoE expert GEMMs were
flat (+1.8 %/+1.4 %) and `wait copy`/dequant did not improve. That is exactly the
FMLA32 issue-rate path the unlock targets; decode is power/GPU-wait bound and gains
nothing.

The work also measured the upper bound for the haohervchb-style unlock: the same
selection of phases is what a full-rate FMLA32/IMLA4 would accelerate, and those are a
few percent of prompt time outside the MoE/copy walls - so the practical difference
between the two approaches would have been small even if the EFI payload had been
applicable.

## Safety evidence from the test

- **No persistent writes:** the module only writes BAR0 MMIO registers, loads and runs
  the pinned firmware into the GPU's protected memory, and writes the two selectors
  through the GPU's own Booter finalize path. No VBIOS/SPI flash access was observed in
  the source or the boot log. The unlock is volatile: a power cycle restores the locked
  state (upstream and self-evident for register/strap state).
- **Failure handling:** the module refuses unknown pre-write states, skips cards with a
  driver already bound, does a PCIe FLR when needed, and on a firmware-quiesce failure
  retains its DMA buffers with an explicit "power off the machine before you try again"
  message rather than continuing. A failed unlock logs and the boot continues locked.
- **The test boot:** one-shot systemd-boot entry (normal generation remained the
  default; `bootctl set-oneshot`), initrd carried the module + six firmware files, no
  VBIOS or loader default changes. Boot reached ssh in ~75 s; kernel log showed
  `unlock result: ss0=0x88888888 ss1=0x8 readout=0x0`, `TU102 FEAT UNLOCKED`,
  `pci 0000:17:00.0: turing_unlock: unlocked`; nvidia 595.71.05 bound normally; no Xid,
  no NVRM errors, idle 41 C.
- **Benchmark safety:** both measurement windows ran at 200 W (and the production-cap
  confirmation at 280 W) with a 2 s temp/power monitor and an auto-abort at 85 C/Xid:
  temp max 60 C, power max 298.7 W against the 280 W cap (brief 2 s sample), throttle
  reasons only SW power cap, no Xid, no thermal event. The card already runs at 280 W
  under the lane's normal prefill load; the unlock changes issue rate, not clocks or
  voltage, and the power cap binds in both states.
- **Recovery path:** the host's BMC answers IPMI (`ipmitool chassis power status`
  works from the OS), so a boot that ever hangs can be power-cycled remotely; a normal
  one-shot boot also returns to the locked generation if the experiment is not
  re-armed.

## Adoption

`hardware.turingUnlock.enable = true` on tiberius:
`pkgs/turing-unlock` builds the upstream module against the plain nixpkgs kernel of the
booted version (version asserted at evaluation time; the host's fsdax kernel patch does
not change the module ABI and CONFIG_MODVERSIONS is off, so the vermagic is the only
handshake) and generates the six firmware images at build time from two pinned NVIDIA
610.43.03 artifacts fetched by hash. **The firmware is never committed to this public
repository** (NVIDIA licence; personal local packaging), and no vendor blob is stored in
the repo; the derivation references the pinned URLs/hashes and the GPL-2.0 upstream
source. This leaves one maintainability cost: if NVIDIA/CachyOS remove those exact
archived artifacts, a from-scratch rebuild of the firmware derivation needs a mirror
(store-realized outputs survive GC until collected; the URL rot is recorded here).

Disable with `hardware.turingUnlock.enable = false;` + rebuild + reboot (the volatile
unlock disappears on the next boot either way). If a future NVIDIA driver or kernel
change breaks the module, the boot continues locked and disabling the option removes it
from the initramfs.

## Residual risks and revisit conditions

- Single-success evidence: one card, one boot, one driver generation (595.71.05) and a
  single ~10-minute benchmark; upstream tested 575.51.03 and warns that full-rate
  tensor cores draw high power. Long-duration stability is not established. Watch the
  telemetry (GPU temp/power, Xid) after adoption; keep the 280 W cap.
- Power/thermal damage is the only credible hardware risk (the module does not flash
  anything); the measurement stayed inside the existing cap at <=60 C, but this is a
  judgement the owner accepts explicitly.
- The 22 GB VRAM mod is not a stock configuration; the module's device table covers
  `10de:1e04` and the selectors were written/read back correctly, but nothing guarantees
  every VBIOS/board variant.
- Revisit (disable) if: any Xid/NVRM error appears under load, GPU temperature reaches
  the telemetry warning (82 C) in normal service, a new driver or kernel makes the
  module fail or the initrd gain disappear, or the measured prefill gain is not
  reproduced by a fresh A/B after an engine/driver change.
- The haohervchb EFI path is still not worth pursuing on this hardware: same target
  registers, an inapplicable board-specific payload, and a worse failure mode for a
  few percent of additional prompt time at most.
