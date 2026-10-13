# Tiberius kernel tuning for the strata lane — options, measurements, A/B plan

Status: **complete for this round.** Written 2026-10-12; the arms it staged were booted
and measured (§7), the engine-side winner was promoted into `pkgs/strata-sm75`, and the
test arms were then removed from `hosts/tiberius.nix` (§4). What remains open is listed in
§9 and in the companion `tiberius-latency-tricks.md`. Labels: **[M]** measured, **[D]**
derived arithmetic, **[E]** estimate, **[P]** pending.

## 1. Bottom line

The kernel is a **second-order lever** for this workload, and the measurements say
why: the Optane module reads at **6.8–6.9 GB/s on every access path** (mmap,
registered-DMA window, SM zero-copy — flat across queue depth; the 12.2 GB/s PCIe
link is reachable only from DRAM) and only **1 of 6 memory channels is populated**
[M, `maya-optane-recon.md` §2b]. Decode cost is `bytes/token ÷ 6.8 GB/s`, and the
levers that move it are engine-side (VRAM expert-cache hit rate, route tail skip,
refill pinning) — all already in the engine.

What a kernel arm *can* touch here is narrow and measurable: the `cudaHostRegister`
pin/unpin path on DAX pages (mm/gup.c — already patched by
`pkgs/kernel-patches/fsdax-longterm-pin.patch`), the per-batch refill
register/merge/copy sequence (**0.040 ms vs 0.867 ms per 2 MiB** registered vs
pageable [M]), page-fault/TLB behaviour on the host arenas, and wakeup latency in
the serialized copy→kernel→copy decode chain. Expected deltas: **low single-digit
percent [E]**; anything larger would contradict the 6.8 GB/s wall.

## 2. The option surface (upstream README "Optional Arguments")

`mkCachyKernel` (pin `b133239`) accepts, with the config symbol each one flips
[M, generated configs + `kernel-cachyos/cachySettings.nix`]:

| arg | values | effect |
|---|---|---|
| `lto` | `none`(default)/`thin`/`full` | `CONFIG_LTO_CLANG_THIN/FULL`; switches toolchain to clang/lld |
| `processorOpt` | `x86_64-v1`(default)/`-v2`/`-v3`/`-v4`/`zen4`/`native` | `GENERIC_CPU` vs `X86_64_VERSION=4` vs `X86_NATIVE_CPU` (impure; `native` breaks reproducible evaluation → **rejected**) |
| `cpusched` | `eevdf`(default)/`bore`/`bmq`/`rt`/`rt-bore`/`null` | `SCHED_BORE`, `SCHED_ALT`+`SCHED_BMQ`, `PREEMPT_RT` |
| `hzTicks` | `1000`(default), `100`…`750`, `null` | `CONFIG_HZ` |
| `tickrate` | `full`(default)/`idle`/`periodic`/`null` | `NO_HZ_FULL` / `NO_HZ_IDLE` / `HZ_PERIODIC` (+`CONTEXT_TRACKING` for full) |
| `preemptType` | `full`(default)/`lazy`/`voluntary`/`none`/`null` | `PREEMPT_DYNAMIC`+`PREEMPT` / `+PREEMPT_LAZY` / `PREEMPT_VOLUNTARY` / `PREEMPT_NONE` |
| `hugepage` | `always`(default)/`madvise`/`null` | `TRANSPARENT_HUGEPAGE_ALWAYS` vs `_MADVISE` |
| `ccHarder` | `true`(default) | `CC_OPTIMIZE_FOR_PERFORMANCE_O3` instead of `_O2` |
| `kcfi`, `hardened`, `rt`, `acpiCall`, `handheld` | off | CFI / hardening / RT / ACPI-call / handheld patch sets |
| `bbr3` | `false` | BBRv3 congestion control (network only — irrelevant here) |
| `autofdo` | `false` | requires `lto != none` + a profile; untested upstream |
| `patches`/`prePatch`/`postPatch` | `[]`/`""` | extra patches — the hook that carries our fsdax patch |
| `autoModules`, `zfsVariant` | `true`, `"latest"` | module coverage; zfs source selector (built kmod is keyed on the kernel, see §4) |

Variant defaults worth knowing: `latest` = eevdf, HZ 1000, preempt full,
THP always, LTO none; `server`/`server-lto` = **Hz 300 + preempt none**;
`bore` = bore scheduler; only `latest`/`lts`/`bore` have `-x86_64-v2/v3/v4/-zen4`
sub-variants; no `-v*` variants exist for `server`.

## 3. What the generated configs actually show (this pin, [M])

Built `configfile` for 7 candidate definitions and diffed against the running
stock kernel:

| symbol | stock 6.18.54 (running) | cachy latest 7.2.8 | cachy server 7.2.8 |
|---|---|---|---|
| `CONFIG_HZ` | 1000 | 1000 | **300** |
| preemption | `PREEMPT_DYNAMIC` + `PREEMPT_LAZY` | `PREEMPT_DYNAMIC` + `PREEMPT` | static `PREEMPT` (flake intends `PREEMPT_NONE`; the defconfig merge resolves to `PREEMPT=y` — generated config is ground truth) |
| `CC_OPTIMIZE_FOR_PERFORMANCE*` | `_O2` | `_O3` | `_O3` |
| `TRANSPARENT_HUGEPAGE` | `MADVISE` | `ALWAYS` | `ALWAYS` |
| `NO_HZ_FULL` | y (inert: no `nohz_full=` on the cmdline) | y | y |
| `NR_CPUS` | 384 | 8192 | 8192 |
| `FS_DAX`/`DEV_DAX`/`ZONE_DEVICE` | y / m / y | y / m(+`DEV_DAX_FSDEV`) / y | same |
| CachyOS-only symbols | — | `SCHED_CACHE`, `SCHED_POC_SELECTOR`, `ARCH_HAS_LAZY_MMU_MODE`, `IOMMU_PT_*`, `RCU_*` tuning | same |

`cachy-latest` has **1471** config diffs vs stock, but stock is 6.18.54 while the
CachyOS arm is 7.2.8, so **the delta bundles a kernel-version jump and is not
attributable to CachyOS alone** — a stock 7.2.x baseline does not exist in this
nixpkgs. `tickrate=idle` was verified to flip `NO_HZ_FULL=y` → `NO_HZ_IDLE=y`
[M], so the mapping is real and not inert.

Also measured on the box: **`iommu_groups=0`** with "Default domain type:
Translated" in dmesg — the IOMMU-passthrough lever (`iommu=pt`) is **closed**;
THP sysfs is `madvise` (cmdline override `transparent_hugepage=madvise`), and
`HugePages_Total=0`, i.e. the engine's `MAP_HUGETLB` path is **unavailable** (it
logs the MADV_HUGEPAGE fallback) — see §5 for the arm that targets this.

## 4. The arms that were staged (and then removed)

The two arms below were wired as specialisations — extra systemd-boot entries, so
the default stayed stock 6.18.54 + fsdax pin and a bad arm was one menu selection
away from being ignored — staged into generations 77/78, measured one arm per boot
(§7), and then **removed again from `hosts/tiberius.nix`** once the verdict was in:
`preempt-full` was a clean null, and the CachyOS arm bought ≤0.6 % for a full local
kernel build on every kernel bump. Generations 77/78 still carry the entries until
the next rebuild; the config no longer defines them. The table is kept as the record:

| arm | kernel | what it isolates | build cost |
|---|---|---|---|
| *(default)* | stock 6.18.54 + fsdax patch | baseline | 0 (built) |
| `kernel-cachy-v4` | `linuxPackages-cachyos-latest-x86_64-v4` (7.2.8) + inherited fsdax patch, variant `zfs_cachyos` | O3 + v4 codegen + CachyOS patch set + 7.2.x | one local kernel build: the *unpatched* v4 kernel is on lantian (`lp7hyib6j7dvz4zjk43qygnq0f5rnqp6` [M]) but our patch changes the derivation, and the v4-paired `zfs_cachyos` is not on any cache |
| `preempt-full` | stock kernel, cmdline `preempt=full` | preemption-only (stock is `PREEMPT_DYNAMIC`) | 0 (cmdline only) |

Verified by evaluation [M]: the arm resolves to `linux-cachyos-latest-x86_64-v4-7.2.8`,
kernel patch list `["fsdax-longterm-pin"]` (applied by the NixOS `kernelPatches`
`apply` hook on top of the CachyOS stack — not double-applied), `boot.zfs.package`
= `zfs-all-2.4.4-7.2.8` for that kernel, and the host's params
(`fsdax_longterm_pin=1`, `zfs.zfs_arc_max=1610612736`, consoles) are inherited.
The variant `zfs_cachyos` is defined inside the variant's package set with
`final.callPackage`, so the NixOS `boot.kernelPackages` `apply` hook (which
overrides `kernel` with the patched one) makes it build against the **patched**
kernel — an exact pairing, not the mismatch one might expect (verified: the arm's
zfs drv on tiberius is a different derivation from the standalone-eval one).
The driver is *not* held constant by this arm: the CachyOS package sets come from
the kernel flake's own nixpkgs, so the arm moves nvidia 595.71.05 → 595.104.02
[confound, accepted: the older driver is not paired with 7.2.8 anywhere].

**Rejected arms and why:** `server`/`server-lto` (HZ 300 + non-dynamic preemption
= worse wakeup latency for a GPU-chained engine); any `*-lto` (10× build cost for
kernel-only codegen an userspace/GPU-bound engine barely executes); `processorOpt
native` (impure evaluation would break `scripts/validate` and reproducible
evaluation — `x86_64-v4` is exactly this CPU's ISA baseline: `avx512f/bw/cd/dq/vl`
+ `avx512_vnni` verified in `/proc/cpuinfo`, while Cascade Lake lacks the
VBMI-class ops that made the Zen4-built strata binary SIGILL); `hardened`/`rc`
(no relevance); `tickrate=idle` (inert while `nohz_full=` is unset); THP-always
cmdline (FSDAX PMD mappings do not come from the THP knobs, and the engine already
requests `MADV_HUGEPAGE`); `iommu=pt` (no IOMMU groups).

## 5. Levers that are *not* kernel arms (and dominate it)

**(a) AVX-512/VNNI expert kernels — blocked by exactly one intrinsic [M].**
The deployed engine (0.1.43, sha256 `a51c0c60…`) *does* use AVX-512: 15,963 `%zmm`
instructions in 211 functions, in two groups:
- the engine's own expert kernels (12,177 EVEX-required ops in 56 `strata::`
  functions), behind `cpu_avx512_ok()` at `expert_layout.cpp:41-72`, which requires
  F ∧ BW ∧ VL ∧ VNNI ∧ **VBMI**. This Cascade Lake part has no VBMI, so the gate is
  false and the log line "this CPU has no AVX-512 … AVX-2" refers to *this tier
  only*;
- ungated code (ggml-cpu built with `-march=native`, plus `act_quant_q8_1`), all of
  it F/DQ/BW/VL/VNNI — executable here.
The VBMI dependency is **two sites, both 2-bit Q2_0 unpacks**:
`_mm256_multishift_epi64_epi8` in `unpack_q2_0()` at `expert.cpp:127` and
`_mm512_multishift_epi64_epi8` in `unpack64_q2_0()` at `expert.cpp:157` (inlined
into the row-dot/expert kernels) — replacing only the 512-bit one would leave the
file, and the flag, VBMI-bound. `cpu_avx512bw_ok()`
(F ∧ DQ ∧ BW ∧ VL, `expert_layout.cpp:74-104`) is already written and is **dead
code — no caller**; note it does *not* test VNNI, which these kernels need, so the
gate change went into `cpu_avx512_ok()` (which already tested ECX[11] VNNI)
rather than reusing it. Enabling the AVX-512/VNNI expert tier here is therefore a
source-level change: replace both unpacks with a VBMI-free equivalent and gate on
F/DQ/BW/VL/VNNI — see §5(a2) for what was built, measured and promoted. **Measured
2026-10-12: ~5 % cheaper CPU expert `pool+plan` per decode window, GPU wait and Optane
reads unchanged, parity 0 failures against the ggml references** — it was the largest
identified CPU-side lever, and it is orthogonal to the kernel.
**(a2) The AVX-512 arm, as built (2026-10-12).**
`pkgs/strata-sm75/avx512-bw-tier.patch` makes that tier reachable on this CPU:
- `unpack_q2_0` / `unpack64_q2_0` (`expert.cpp`) expand the fixed shift pattern
  `0x0E0C0A0806040200` with `VPERMW` + `VPSRLVW` + `VPMOVWB` instead of
  `VPMULTISHIFTQB` — identical layout (`byte k = (u16 >> 2(k%8)) & 3`), verified
  exhaustively against a scalar reference (0 mismatches over 200 k random 8-u16
  vectors plus edge cases) and cheap enough (4 instructions per 32 codes) that a
  null result is attributable to the tier, not to the substitute;
- `cpu_avx512_ok()` drops the VBMI requirement → F ∧ DQ ∧ BW ∧ VL ∧ VNNI;
- `CMakeLists.txt` drops `-mavx512vbmi` from **both** AVX-512 translation units
  (leaving it on would let the compiler emit VBMI elsewhere in them — exactly the
  SIGILL class `docs/VALIDATION.md:245-262` documents).

Static proof on the built binary: **0** VBMI-class opcodes against 296
`vpmultishiftqb` in the deployed control, VNNI dots intact (993 `vpdpbusd`).
Measurement design: three arms — deployed engine, patched +
`STRATA_FORCE_ISA=avx2`, patched + default — because the first two execute the
*same* AVX-2 code, so their spread is the harness's noise floor for this box;
`STRATA_NO_IQ512=1` gives an extra IQ512-vs-IQ256 read. The engine's own
`expert_parity --selftest` / `native_expert_parity <shard.gguf>` are the numeric
gate; the A/B's answer texts are the end-to-end one.

**Measured (2026-10-12, ab18 campaign; 3 counterbalanced runs per arm; A = deployed,
B = patched + `STRATA_FORCE_ISA=avx2`, C = patched).** A and B are indistinguishable
and produce **bit-identical answers** (decode −0.27 % / −0.11 %, per-window CPU cost
−0.04…−0.10 %): the noise floor and the neutrality check. C is *not* bit-identical to
the AVX-2 tier on the long cells — last-bit numerics re-route speculative sampling
(all nine answers stay fluent and on-topic) — so the raw decode deltas (+11.7 % P1 /
−2.6 % P2) are a **trajectory artefact** (windows 110 → 101 on P1, 99 → 107 on P2;
draft acceptance 68 % → 79 % and 80 % → 72 %; cache hit +0.6…1.1 pt), not a speedup.
The deconfounded per-window CPU cost (gpu wait + pool+plan + staging + commit) moves
92.02 → 91.17 ms (−0.93 %) P1, 81.14 → 77.47 (−4.52 %) P2, 90.15 → 85.84 (−4.78 %) P3,
with **GPU wait identical** (17.8–18.0 ms) and `pool+plan` alone −1.1 % / −5.7 % /
−5.9 %; prefill and Optane reads are unchanged (within 0.4 %). P3 is trajectory-matched
(27 windows in every arm, bit-identical text), so the defensible claim is:
**≈5 % cheaper CPU-side per decode window, end-to-end within a few percent either way**,
invisible under speculative decoding — and it *changes the output text* deterministically,
so making it the default is a product decision, not a perf toggle. `native_expert_parity` ran against the real shards with
the AVX-512 tier live on this Cascade Lake and reported **0 failures**: the
i-quant gate rows matched the ggml reference at rel `9.90e-08` (iq3_xxs) and
`9.84e-08` (iq2_s), and the Q2_0 consumer this patch rewrote matched at rel
`2.25e-04`; width invariance held (0 rows differ), and the GPU halves were
bitwise-equal once `LD_LIBRARY_PATH` pointed at the driver libs.

*Residual gap:* `expert_parity --selftest` and `expert_multi_test` still SKIP
their VNNI check on this CPU ("missing AVX512-VBMI") because a **test-facing**
probe — `CpuFeatures::usable()` (`include/strata/kernels/cpu/expert.hpp:97`) and
`cpu_features()` (`expert_layout.cpp:314`) — kept the VBMI requirement that
`cpu_avx512_ok()` dropped. Those two gates therefore do not execute here; the
numeric evidence above comes from `native_expert_parity`, which exercises the real
kernels. Relaxing the probe the same way is a small, separate change (worth
offering upstream rather than smuggling into this patch).

**Promoted 2026-10-12** into `pkgs/strata-sm75/default.nix` (`patches` entry + build-failing
guards: no `multishift_epi64_epi8`, `_mm512_srlv_epi16` present, no `;-mavx512vbmi;` in the flag
lists). The promoted output is a *different* store path from the measured build (the guards are part
of the derivation), but `.text`, `.rodata`, `.data` and `.nv_fatbin` are **byte-identical** — only the
embedded self-references differ — so the ab18 baseline stays valid. The running unit points at that
build and its log no longer contains the AVX-2 fallback line.

**(b) Hugepages for the host expert tier — a *conditional* lever [M].**
`HugePages_Total=0` and the live log has **no** `MAP_HUGETLB`/hugepage line at all:
production runs the complement tier **pageable** (`… resident 1.00 GiB, pinned
0.00 GiB`, `host expert tier: pageable, capped at 1024 MiB`) because the config
sets `STRATA_RESIDENT_PIN=0` and `STRATA_RESIDENT_HEADROOM_GIB=0`. The hugetlbfs
knob (`vm.nr_hugepages` + a hugetlbfs mount) only becomes meaningful once the
*pinned* resident tier is re-enabled, and earlier campaigns already found pageable
and pinned tiers byte-identical (`docs/VALIDATION.md:210-235`) — so test
`STRATA_RESIDENT_PIN=1` (engine-side, no rebuild) before reserving anything.
**Closed 2026-10-13 [M]** by the companion `tiberius-latency-tricks.md`: the pack is
already 2 MiB PMD-mapped (`FilePmdMapped` 71.9 GB against ~20 MB of PTEs), the anonymous
arena is only ~1.37 GiB, and the box already swaps ~1.07 GB with a 948 MB ARC — so a
hugetlbfs reservation spends non-swappable GiBs for a lever whose *pack* half is already
satisfied. Considered and rejected on those numbers, not left open.

## 6. Measurement protocol

1. Harness [M]: `/data/ab17.py` + `/data/ab17-arms.sh` + `/data/ab17-serve.sh`
   (runlist-driven, prod service stopped under a GPU flock with an `EXIT`-trap restore;
   ~80–90 s per run, ~13–15 min for 3+3 counterbalanced runs). The **kernel** A/B of §7
   used the one-armed session runner `/root/kernel-ab.sh` instead: same `ab17` driver over
   the ab18 cells, one arm per boot, self-tagging by `uname -r` into `/data/kab/<kernel>/`
   (it lived on the impermanent root — recreate it from §8's notes or the `/data/kab-*`
   helpers).
   Workload `/data/real-corpus.txt`, cells P1 4292 tok / P2 3517 tok / P3 62 tok,
   256 gen (96 for P3). Invocation:
   `ssh root@tiberius 'AB_TAG=abK RUNLIST="A-1 B-1 B-2 A-2 B-3 A-3" /data/ab17-arms.sh'`.
   Artifacts per run: `/data/abK-<arm>.log`, `-metrics-<arm>.json`, `-answer-P*.txt`,
   `-arms.log`, `-engine.json`; parse with the `ab10-parse.py` regexes (read_ms,
   prefill tok/s, gen_ms, decode tok/s, hit%, drafts, skipped).
   The harness is kernel-agnostic (no variant/hugepage awareness anywhere in
   `/data`), so a kernel A/B is: boot arm A → run → boot arm B → run, keeping the
   runlist counterbalanced *within* each session and reporting arm means.
   Record per session: `uname -r`, `/proc/cmdline`,
   `/sys/kernel/debug/sched/preempt`, Optane temperature, and the engine's own
   `decode expert cache hit rate: NN.N %` line (the ab17 baseline is 82.3 %).
2. Arms run **counterbalanced pairs**, 3 runs each, alternating arms within one
   session; record `uname -r`, `nohz`/preempt mode, Optane temperature.
3. Confounder: the DIMM runs **82 °C of 85 °C critical** under strata load [M,
   `docs/VALIDATION.md:329-357`] — thermal drift can swamp a low-single-digit
   effect, so alternate arms and keep sessions short.
4. **Noise floor and kill criterion.** The harness's own repeatability is on
   record: 3 counterbalanced runs per arm gave a per-arm spread of ≤0.1 tok/s
   (≈0.3 %) on the P1/P2 decode cells, and the v0.1.43 cross-arm decode agreement
   was within 0.1 % (`docs/VALIDATION.md:217-232`). So a decode delta inside
   ~0.5 % is **unmeasurable on this box** — report it as "no measurable
   difference" rather than a point estimate, and quote per-arm means *and*
   spread. Prefill cells and the `pool + plan` / refill timings are the more
   legible signals for a CPU-side change. An arm that worsens the refill
   ms/copy table, or moves decode by <0.5 % with no prefill movement, is
   abandoned and the default arm stays.

## 7. Kernel A/B result (measured 2026-10-12/13, one arm per boot, 3 runs each)

| cell | stock 6.18.54 (+fsdax) | CachyOS `7.2.8-cachy-v4` | stock + `preempt=full` |
|---|---|---|---|
| decode P1 / P2 / P3 (tok/s) | 27.97 / 30.53 / 23.17 | 28.07 / 30.70 / 23.27 | 27.97 / 30.50 / 23.13 |
| prefill P1 / P2 / P3 (tok/s) | 461.13 / 387.47 / 26.60 | 463.80 / 387.37 / 26.63 | 460.57 / 386.63 / 26.57 |
| pool+plan per window (ms) | 73.21 / 59.58 / 67.79 | 73.11 / 59.48 / 67.67 | 73.28 / 59.62 / 67.84 |
| hit % / drafts / skips / windows | 82.9·87.2·66.1 / 158-200,151-211,35-40 / 30699 / 101,107,27 | identical | identical |

- **Cachy-v4 vs stock: decode +0.36 % / +0.56 % / +0.43 %**, prefill within ±0.6 %, `read_ms` −0.57 %
  on P1 — nothing above ~0.6 %, and the arm is **confounded**: it also moves nvidia 595.71.05 →
  595.104.02 (the CachyOS package sets bring their own nixpkgs driver), so even that small delta is not
  attributable to the kernel alone.
- **`preempt=full` vs stock: every delta ≤0.22 %, decode ≤0.17 %** — a clean null (same kernel binary,
  same cmdline except the one token).
- The engine was constant across arms (the promoted AVX-512 build), and the stock session **reproduced
  ab18 arm C exactly** (27.97/30.53 vs 28.00/30.50 tok/s, hit 82.9/87.2, drafts 158/200 & 151/211, skips
  30699, windows 101/107/27) — closing the promotion transfer question: same code, and the two binaries
  differ in **4 bytes** (the embedded store path) with byte-identical `.text`/`.rodata`/`.data`/`.nv_fatbin`.
- Verdict: **the kernel is not the lever.** A CachyOS v4 kernel buys ≲0.6 % (confounded) for a large
  local build on every kernel bump; `preempt=full` buys nothing. Keep the stock+fsdax default; the
  `kernel-cachy-v4` arm is worth keeping only if 7.2.8 is wanted for other reasons.
- Protocol notes for next time: boot a test arm with the **one-shot** `systemctl reboot
  --boot-loader-entry=<entry-id>` rather than `bootctl set-default <entry-id>` — a failed arm then falls
  back to the normal default on the next power cycle instead of becoming the persistent default. Assert
  the booted kernel *before* measuring (`uname -r`, `/proc/cmdline`, `/sys/kernel/debug/sched/preempt`),
  and note that this box's production env does not set `STRATA_REFILL_TIMING`, so the refill
  `pin_refused`/`pin_skipped` counters are not emitted — DAX/pin health is inferred from `read_ms`,
  hit %, draft counts and skip counts being identical across arms.

## 8. Build logistics (Mac storage is not touched)

- Builds run **on the hosts**, never on the Mac (user constraint 2026-10-12;
  the Mac was at 99 %). `build-dir` on `/optane` kept the kernel tree off ZFS and
  out of the ARC path — but **16 GB is not enough**: the first attempt (46 min,
  tiberius-local, `cores=8`) died with `No space left on device` while compiling
  the module sweep (infiniband/rpmsg/…), because this config is `autoModules =
  `true` and builds ~6 300 modules. `autoModules = false` is *not* a size escape
  (7422 `=m` vs 6297 `=m` [M, generated configs]), so the arm is built
  **remote-only on the builders**: `max-jobs = 0` with the daemon's
  `/etc/nix/machines` left alone. **Do not hand-write a `builders =` spec on the
  command line** — that is what silently suppressed the machines file and made the
  kernel build locally (the failure above). Verified mechanism [M]: with
  `max-jobs = 0` a non-substitutable probe derivation was built on trajanus and
  copied back; the builder's `maxCores` caps `make -j` (wall clock only, not
  correctness). trajanus has 16 threads, 22 GB RAM and 847 GB free on `/nix` —
  its "disk-full, daemon dies mid-build" note in `hosts/tiberius.nix` is stale.
- `tiberius-strata` stops for the duration (measured: `memory.current` 5.04 GiB,
  peak 5.44 GiB [M]); the new kernel only takes effect at the next reboot.
- Nothing is built or copied on the Mac (user constraint, 2026-10-12): no
  `nix build` from here for kernel-sized closures.
- **tiberius' root is impermanent**, and the mechanism is on record rather than guessed:
  `cjv.impermanence.zfsBootRollback` rolls `zroot/local/root` back to a blank snapshot on
  **every boot** (`flake.nix` wires the module, `disko/tiberius.nix` names the root
  dataset, `disko/base.nix` creates `@blank`). Verified when the kernel A/B's three
  reboots wiped `/root/nixos-arm` mid-session (`/` is `zroot/local/root`, the rollback
  target; the other pools are not rolled back). Keep the deployment tree under `/persist`: it
  lives at **`/persist/nixos-arm`** (`zroot/safe/persist` — the dataset that holds the agenix
  secrets and `/persist/strata`), pushed 2026-10-13 and re-pushed whenever the repo moves. `/data`
  (`zdata/local/data`) also survives boots in practice — `/data/real-corpus.txt` is dated
  2026-09-30 across the 2026-10-13 01:28 boot — but the repo stages durable artifacts under
  `/persist` (and picked it for `/data`'s *capacity* in the uncensored-checkpoint unit, not its
  durability), so treat `/data` as the scratch area (`/data/ab17*`, `/data/kab*`). Expect to
  re-push before any rebuild changed the tree.
- Rollback: specialisations are extra entries in the *same* generation as the
  default one; `boot.loader.systemd-boot.configurationLimit = 8` keeps the
  previous generations. Booting the default entry is byte-identical to today.

## 9. Risks

- **NVIDIA driver for 7.2.8** — **cleared [M]**: both halves build against the
  candidate — the userspace `nvidia-x11-595.104.02` *and* the artifact that
  actually binds to the kernel, `nvidia-kernel-modules-595.104.02-7.2.8`
  (`hardware.nvidia.package.mod`, which is what `boot.extraModulePackages`
  carries when `open = false`; a userspace-only build is **not** sufficient
  evidence, since `nvidia-x11` ships no `.ko`).
- **zfs kmod for 7.2.8** — **cleared [M]**: `zfs-all-2.4.4-7.2.8` builds with
  vermagic `7.2.8-cachyos`. It is a lantian **miss**, so tiberius must build it —
  and since `/` is an `x-initrd.mount` ZFS root, the arm must carry a matching
  `boot.zfs.package` (it does).
- **Kernel-patch drift** — **cleared at this pin [M]**: the fsdax patch applies
  cleanly on top of the CachyOS 7.2.8 stack (`linux-src-patched` builds; 3 hunks
  in `mm/gup.c` + `include/linux/mm.h`). Any kernel bump must re-verify this.
- `/optane` holds 109 GB of strata data; the build dir is a separate subdirectory
  and nothing under `strata-data/` is touched.
