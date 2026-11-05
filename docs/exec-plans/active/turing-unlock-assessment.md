# Turing-unlock on tiberius: can it be made to work, and should it?

Status: **assessed 2026-11-05; decision: do not attempt on tiberius.** This is a
decision record for an external research project, not a planned change. The lane keeps
the stock (modded-VRAM) RTX 2080 Ti behaviour.

Upstream: <https://github.com/haohervchb/Turing-unlock> (haohervchb/Turing-unlock,
last commit 2026-10-22, published as a board-specific research archive). All performance
figures below are **the upstream project's own claims**, not re-measured here.

## What the project is

A volatile, pre-OS tensor-compute unlock for one specific TU102 board. An EFI payload
writes NVIDIA Resource Manager (RM) controls through a guarded direct-physical high-RAM
DMA path before Linux boots; RM then reports **FMLA32 and IMLA4 at full rate instead of
half rate**. Upstream measured on its test card: FP16-in/FP32-accum MMA 511.67 ->
1022.44 FLOP/SM/clock (1.998x), 46.94 -> 93.66 TFLOPS (1.996x), cuBLAS 8192 GEMM
48.15 -> 85.17 TFLOPS (1.769x); FP16-in/FP16-accum was unchanged. No extra SMs, cores,
Tensor Cores or VRAM were enabled. An integer/mining run (Pearl, PeakMiner) showed **no
meaningful gain**, and IMLA4 never got a dedicated throughput A/B.

It does **not** flash a VBIOS or modify a live Linux GPU. One physical v4 run succeeded
on 2026-10-22; the unlock is volatile (a normal restart reverted it), automatic
reapplication is **not implemented or enabled**, and the published boot entry is a
one-shot example, not a supported default.

## Why it cannot simply be run here

The public checkout is deliberately not a working payload for arbitrary cards. Its
build requires private inputs that are *not* redistributed and are pinned by hash:
the exact native FWSEC extracted from the test card's own ROM, the audited Dell A14
root-bridge PE image, and input blobs from a pinned `xrip/cmp50hx-unlock` checkout.
The runtime guards check the exact PCI BDF (`0000:02:00.0`), vendor/device
(`10de:1e07`), subsystem (`1043:866a`), BAR0 (`fa000000`), PCI command (`0007`), the
parent bridge, firmware descriptor bytes and a finite set of observed selector tuples;
unknown pre-write states refuse. The ESP GUID is all-zero and the boot example has a
placeholder filesystem UUID. Possessing "an apparently similar GPU" is explicitly not
enough.

tiberius differs at every layer that matters:

| | upstream test card | tiberius |
|---|---|---|
| device | `10de:1e07` (TU102, 11 GiB, 68 SMs) | `10de:1e04`, 22 GB mod, VBIOS `90.02.17.40.0E` |
| subsystem | `1043:866a`, ASUS RTX 2080 Ti Rev. A | `1043:8687`, ASUS 22 GB mod |
| BAR0 / BDF | `fa000000` / `0000:02:00.0` | `f3000000` / `0000:17:00.0` |
| board/firmware | Alienware Area-51 R2, BIOS A14, Dell root bridge | TYAN S5630GMRE-CGN, AMI 7.206.B80, systemd-boot UEFI |
| boot state | Above-4G decoding **off**, CSM **on** | headless UEFI server boot; 128 GB DCPMM; impermanent root |
| driver | unmodified NVIDIA open `580.178.04` | NVIDIA `595.71.05` |

A second card (upstream tried an RTX 5060 Ti) already changed enough preboot state to
make the guards refuse; an unknown 22 GB VBIOS mod on a different board is a much larger
delta. Adapting the guards/firmware to this card would require the private inputs for
*this* board and its own platform/firmware audit - the project warns, in its own words,
not to weaken the identity/DMA guards to make a build run.

## Could it work safely with different hardware?

Only as a separate research effort, not as a lane change:

1. A **spare** identical card (ASUS `1043:866a`, VBIOS `90.02.17.00.47`, 11 GiB) and a
   board close to the tested Alienware A14 (or the original board), plus the private
   firmware inputs from that exact machine.
2. A test rig where a failed mutation (upstream: boot held in UEFI, full power cycle
   required) costs nothing, plus an offline boot-flow with the in-progress/failure
   marker and a normal-boot bypass described in upstream `docs/BOOT-STATUS.md`.
3. A successful bounded physical attempt, then upstream's read-only RM verifier and
   the SM75 tensor benchmarks re-run on the exact rig before anything production-adjacent.

The firmware-free host tests (`tools/test_preflight.sh`) can be built and run on any
x86-64 Linux; they never touch a GPU, but they only exercise the loader's simulated
paths and prove nothing about this card.

## Why it should not be attempted on tiberius

- **Blast radius**: the unlock is a pre-OS mutation executed over direct physical DMA on
  the only GPU this box has. Upstream's documented failure mode holds the machine in
  UEFI with DMA backing retained and requires a full power cycle; the box already has a
  ~28 min firmware POST and is the production inference lane. A hang or a partial GPU
  mutation is a recovery incident at best.
- **Not reproducible from the public repo**: the required payload/firmware inputs are
  private and bound to a different board/VBIOS; making it work here is a from-scratch
  platform audit, with no upstream support path.
- **The upside for Strata is small and unproven**: the unlock targets FP16-in/FP32-accum
  MMA and integer IMLA4 *issue rates*. In this engine, dense FP16 tensor-core GEMMs are
  a minority of prompt time (the `STRATA_BF16_TC` measurement moved ~1564 -> 1302 ms of
  kernel time inside a ~9.2 s prompt read; the prompt path is otherwise DAX/Optane-paced
  and the prefill timing attributes most of its GPU time to expert/GEMM/attention work
  that is not this rate). Decode is GPU-verify-window bound with 98-99 % expert-cache
  hits. Upstream's own integer workload saw no gain, and IMLA4 has no dedicated A/B. A
  generous upper bound from doubling the dense MMA rate is low single-digit percent of
  prompt read, and nothing on decode; it would not move the measured fixed-cost or the
  Optane-preill wall the tuning work is aimed at.
- **Persistence is unfinished upstream**: applying it every boot is explicitly not
  implemented; our boot chain (systemd-boot, impermanent root, 27-min POST) would need
  its own wrapper and recovery design on top.

## Decision and revisit conditions

Do not attempt Turing-unlock on tiberius. Revisit only if **all** of these change:
(a) a spare compatible TU102 card + test board (or a published board-generic, audited
profile for this VBIOS/board) exists; (b) upstream ships a supported persistence/recovery
wrapper with the failure marker; (c) a bounded test rig has shown the unlock survives the
boot-flow and repeats FMLA32/IMLA4 full rate; and (d) the engine's remaining bottlenecks
are measured to be FP16/FP32-accum or IMLA4 issue rate, which they currently are not.
Until then the same engineering time is better spent on the measured software levers
(DAX rotation cost, host-RAM admission/park capacity, session handling), not on a
single-card research unlock.
