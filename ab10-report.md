# ab10: v0.1.42's two new CUDA decode defaults on tiberius

Question: v0.1.42 ships two defaults that change what the engine computes - the rank-7
verify tail skip (`STRATA_ROUTE_TAIL_SKIP=7`) and a missed-expert PCIe share measured
from the CPU pool instead of the start-up link probe - and both change answers slightly
(upstream: mean first-token KL ~0.0058 / ~0.0015).  This campaign measured whether either
pays on this box before the module pins them.

Engine: `/nix/store/0sfy8ply05j2i6a4sd9lq9csv5343d48-strata-engine-0.1.42` (the bump's
candidate).  Base config: production-shaped (`ab10-base.json`: 262144/int8/KV_ROT/28160
chunk/resident 1 GiB/DAX window 6144 MiB/`STRATA_PREFILL_CPU_SHARE=0`); the serve layer
and engine both come from the candidate store, isolated on :8099 (unit `ab10-gen`).  The
production service is stopped for the window under `/tmp/strata-gpu.lock` and restored +
`/health`-checked by the harness's EXIT trap.

Cells (fresh engine per run, `/data/real-corpus.txt`, ab8's decode yardstick): P1 =
4,292-token read + 256 gen; P2 = 3,517 + 256.  Arms (three counterbalanced passes: 1
forward - parity ts7 pcie new; 2 reverse - new pcie ts7 parity; 3 rotated - ts7 parity
new pcie; only new-1/new-2 meet in the wrap):

| arm | env |
|---|---|
| `parity-*` | `STRATA_ROUTE_TAIL_SKIP=0 STRATA_PCIE_FRAC_DEFAULT=old` (0.1.41 answers) |
| `ts7-*` | `STRATA_ROUTE_TAIL_SKIP=7 STRATA_PCIE_FRAC_DEFAULT=old` |
| `pcie-*` | `STRATA_ROUTE_TAIL_SKIP=0` + the measured share |
| `new-*` | both v0.1.42 defaults (nothing set) |

Pilot `parity-0`/`new-0` preceded the batch (09:02); 14 runs total, 2026-10-11
09:02-09:22 local (batch 09:05:39-09:21:35; production restored + health-checked by
09:22:09).

## decode tok/s (mean over runs; the within-arm spread is ~0.1 tok/s)

| arm | n | P1 dec | vs parity | P2 dec | vs parity | P1 hit% | P2 hit% |
|---|---|---|---|---|---|---|---|
| parity | 4 | 21.30 | - | 26.05 | - | 78.6 | 85.0 |
| ts7 | 3 | 29.50 | **+38.5%** | 34.43 | **+32.2%** | 85.4 | 89.7 |
| pcie | 3 | 19.80 | **-7.0%** | 24.27 | **-6.8%** | 77.0 | 83.4 |
| new | 4 | 29.38 | +37.9% | 32.75 | +25.7% | 85.4 | 87.8 |

## prompt read (the control: the feature contract is "prompt reading is untouched")

| arm | P1 read ms | pre tok/s | vs parity | P2 read ms | pre tok/s | vs parity |
|---|---|---|---|---|---|---|
| parity | 9237 | 464.6 | - | 8969 | 392.2 | - |
| ts7 | 9217 | 465.7 | -0.2% | 8975 | 391.9 | +0.1% |
| pcie | 9213 | 465.8 | -0.3% | 8981 | 391.6 | +0.1% |
| new | 9202 | 466.4 | -0.4% | 8996 | 391.0 | +0.3% |

## stage 0 (acceptance-free: pool + plan ms per decode window, mean over runs)

| arm | P1 ms/window | vs parity | windows | P2 ms/window | vs parity | windows |
|---|---|---|---|---|---|---|
| parity | 104.8 | - | 115 | 85.7 | - | 208 |
| ts7 | 63.1 | **-39.8%** | 119 | 50.5 | **-41.1%** | 222 |
| pcie | 114.9 | +9.6% | 107 | 92.0 | +7.4% | 210 |
| new | 63.2 | -39.7% | 119 | 55.7 | -35.0% | 211 |

The window counts differ (the arms compute different text: EOS lands elsewhere), but
pool + plan is a strict per-window measure, so it carries the same verdict as the tok/s
table without the draft-acceptance term: the tail skip removes ~40% of the expert work
per window, the measured PCIe share adds ~7-10% to it, and the share also costs +10.3%
on top of the tail skip in P2 (`new` 55.7 vs `ts7` 50.5).

## Engagement (per-run engine logs)

* `parity`: no tail-skip banner, no counters, no PCIe share line - both knobs off.
* `ts7`: banner `STRATA_ROUTE_TAIL_SKIP=7 is ON` + counters 3,078 (warmup) / 14,141 /
  22,328 missed experts skipped of 3,449 / 15,153 / 23,675 entries; no share line.
* `pcie`: share line `PCIe share: ... 0.34 -> 0.50` (326 us per missed expert, 6.3 GB/s
  of expert bytes, link 12.2-12.3 GB/s); no banner, no counters.
* `new`: banner `is ON (default)`; counters 3,078 / 14,163 / 22,963 of 3,449 / 15,178 /
  24,477; share line `0.34 -> 0.50` (328-329 us, 6.2 GB/s).

## Findings

* The tail skip is a large, reproducible decode win on this box (+38.5% / +32.2%), well
  above upstream's +10..20% on 12-16 GB cards.  Mechanism: the 6,282-slot cache of
  24,576 experts misses enough that 14.1K-22.9K missed experts per cell are skipped, and
  a skip removes both the DMA and its compute.  The expert-cache hit rate rises too
  (78.6 -> 85.4 / 85.0 -> 89.7), definitionally rather than by better reuse: skipped
  experts leave the lookup set (P1 hits 114,348 -> 113,273 while lookups fall
  145,532 -> 132,689).
* The measured PCIe share LOSES here: -7.0% / -6.8% decode with the tail skip off, and
  -0.4% / -4.9% on top of it.  It moves the share 0.34 -> 0.50 on every run (the CPU
  pool is 326-329 us per missed expert, 6.2-6.3 GB/s, against the 12.2-12.3 GB/s link),
  i.e. it hands the PCIe path more than the probe's rule did; the arm lost anyway.  The
  start-up probe's auto share stays - ab8 already kept it as the control against
  explicit 0 / 0.5 / 1.0 fractions.
* Prefill read is flat across all arms (+-0.4%), exactly as upstream documents.
* Decode token counts differ between arms (EOS lands elsewhere: P2 226 for parity, 242
  for ts7, 250 for pcie), but every tok/s figure is computed by the engine over its own
  generated window, so arms are compared on the same measure with their own text.  The
  run-to-run identity of each arm's numbers (same drafts, same counters, same hit rate)
  is the cleanest evidence that the arms differ in what they compute, not in noise.

## Build host (why the batch was re-run before shipping)

The engine's codegen follows the BUILD host (`NIX_ENFORCE_NO_NATIVE=0` in the
package; ggml compiles with `-march=native`), and tiberius's `nix.conf` lists pius
(an AVX2-only i5-8400) and trajanus (Zen 4) as remote builders, so a plain
`nix build` dispatches this derivation and the artifact carries the builder's
instructions:

* the first batch ran on `0sfy` (`/nix/store/0sfy8ply...-strata-engine-0.1.42`),
  built on trajanus; a second trajanus build of the next drv (`c7mnx`) differs
  from it in **4 bytes**, while a pius build of the same drv differs in
  **50,132,344 bytes**;
* the engine's own AVX-512 expert kernels (`expert.cpp`; they contain 296
  `vpmultishiftqb`) are compiled with explicit `-mavx512f/bw/vl/dq/vnni/vbmi`
  on every build and selected at run time by `cpu_avx512_ok()` =
  F+BW+VL+VNNI+VBMI.  That gate is false on tiberius -- the deployed engine
  logs "this CPU has no AVX-512: the expert kernels run on AVX-2" -- so those
  instructions are dead by design, in the trajanus and the native builds
  alike;
* ggml's `*_generic` fallback dots and `ggml_vec_dot_bf16` instead carry the
  build host's `-march=native` with no run-time gate: the trajanus binaries
  have 262 instructions the Xeon Gold 6246 cannot execute (260 `vpermt2b` /
  AVX512-VBMI in the q3_K/q5_0/q5_1/q6_K generic kernels -- 128 each in q3_K
  and q6_K -- and 2 `vdpbf16ps` / AVX512-BF16 in `ggml_vec_dot_bf16`), the
  native build has 0 of them, and the deployed v0.1.41 (also trajanus) carries
  the same 262.  They were NOT reached in this config (16 campaign runs, and
  v0.1.41 in production since 2026-10-09, ran clean), but they are one
  fallback kernel away from a SIGILL for another quant type or lane;
* `preferLocalBuild = true` was added to `pkgs/strata-sm75` so the engine is
  built on the host that runs it (verified: the box built it locally, 44
  compiler processes, no `ssh-ng` line); `-DGGML_NATIVE=OFF` remains the
  portable fallback for a non-tiberius consumer.

The batch was therefore re-run on the tiberius-native artifact that ships (below),
with the same scripts and arm order.

## Native re-run (ab10n, the shipped artifact)

Same design and scripts on the tiberius-native engine
(`/nix/store/njsg0254ks9fkllc7ia5mbgpcqzkhdn1-strata-engine-0.1.42`, 0 of the
builder-only VBMI/BF16 set), 2026-10-11 ~10:00 local, 12 runs:

| arm | n | P1 dec | vs parity | P2 dec | vs parity | pool+plan P1 | pool+plan P2 |
|---|---|---|---|---|---|---|---|
| parity | 3 | 21.30 | - | 26.03 | - | 104.8 ms | 85.6 ms |
| ts7 | 3 | 29.50 | +38.5% | 34.50 | +32.5% | 63.0 ms | 50.4 ms |
| pcie | 3 | 19.80 | -7.0% | 24.27 | -6.8% | 114.9 ms | 91.9 ms |
| new | 3 | 29.40 | +38.0% | 32.80 | +26.0% | 63.1 ms | 55.6 ms |

The same hit rates, skip counters (3,078 / 14,163 / 22,963 of 3,449 / 15,178 /
24,477 for `new`) and share movement (0.34 -> 0.50) as ab10 -- the arms compute
the same routing -- and the same verdicts to within 0.1-0.3%: the pins are
measured on the artifact that ships.

## Decisions

* Adopted: `STRATA_ROUTE_TAIL_SKIP=7` pinned explicitly in
  `profiles/nixos/strata.nix` (a future upstream default flip cannot move this box),
  accepting upstream's drift (mean KL 0.0058, top-1 agreement 97.7%, PPL x1.011;
  their HumanEval/reasoning sets within their own noise) for +38.5% / +32.5% decode
  (the native run's numbers).
* Pinned: `STRATA_PCIE_FRAC_DEFAULT=old` (the variable's only other value); unset adopts
  upstream's measured rule.
* The build-time greps in `pkgs/strata-sm75` now cover both variables.

## Files

`/data/ab10.py`, `/data/ab10-arms.sh`, `/data/ab10-serve.sh`, `/data/ab10-base.json`,
`/data/ab10-parse.py`; per-run engine logs `/data/ab10-<arm>-<run>.log` (14) and
`/data/ab10n-<arm>-<run>.log` (12, the native build); `/metrics` dumps
`/data/ab10{,n}-metrics-<arm>-<run>.json`; batch logs `/data/ab10-arms.log` and
`/data/ab10n-arms.log`; workstation copies `ab10-report.md` and
`ab10-raw-lines.txt` (both datasets).
