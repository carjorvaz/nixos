# qwen38-sm75: banking the measured Turing levers

Status: active (2026-09-16).

## Goal

Carry the already-measured 2080 Ti campaign results into the pinned
`qwen38-sm75` 0.28.0 package, and close the remaining open kernel/observability
items with measurement rather than inference. Non-goal: chasing the RTX 3090
reference numbers with kernels that cannot exist on sm75 (no fp8, no bf16
tensor arithmetic, no Marlin sm90 paths).

## Evidence this plan is built on

Recorded in three private campaign trees (2026-09-05/06/10) and summarised
here in public-safe form:

- Campaign X, same GPU, campaign fork (131k, MTP3, C4 agent suite, 280 W):
  `--prefix-match-unit 1` +19.6 % with a bit-identical PPL; W4A8 int8 on the
  MLP projections +6.9 % at PPL +0.78 %; the composition +27.4 % at 128/128
  cases and zero paired new losses.
- Closed negative on that runtime: DFlash2 port (acceptance 1.12-1.29 against
  MTP3's 3.61, -57.8 %), MTP depth 2/4, async scheduling (-16.7 %), custom
  RMSNorm/SiLU graph ops (-0.6 %), prefill chunk sizing, Marlin M-scaling,
  KV read path, TurboQuant/native 262144 as speed.
- Left unrun there: the Triton butterfly Hadamard for the d=256 inverse RHT
  (2.6 ms/step, 5 % of every decode step) and the GDN decode kernel
  (6.5 ms/step, 12.4 %).
- The card is factory-capped at 250 W and supports 280 W; +1.6 % measured at
  280 W with the clock rise independently observed, and the limit reverts on
  every driver load.
- The open kernel module + GSP hit Xid 119 -> 154 twice in two days, each
  time costing a host reboot; the documented mitigation is the proprietary
  module with `NVreg_EnableGpuFirmware=0`.
- Current production baseline (measured on the pinned package): MTP4 decode
  78.65 / 56.72 / 27.26 tok/s at 8k / 32k / 128k prompt; MTP3 70.85 / 51.49 /
  24.68; cold 32k TTFT 44.79 s against 0.44 s cached; live MTP4 acceptance
  3.42 tokens/step and a 70 % prefix-cache hit rate.

## Changes landed with this plan

- `pkgs/qwen38-sm75/patches/turing-rht-butterfly.patch` (from the campaign):
  one Triton butterfly kernel replaces the PyTorch stage loop for fp32
  `single_rht` at d=256. The call sites already pass `.float()`.
- `pkgs/qwen38-sm75/patches/zz-upstream-*.patch`: SSE keep-alive (upstream
  #51034), engine stall sentinel, engine completion log, ported to the pin.
- `hosts/tiberius.nix`: 280 W power-limit unit, `--sse-keep-alive-interval 30`,
  `VLLM_ENGINE_STALL_SENTINEL_S=120`, and a two-stage warmup (one 2048-token
  prefill, then the small chat request) so prefill-tile/GDN kernels compile at
  serving shapes.
- `profiles/nixos/gpu/nvidia.nix`: proprietary module, GSP disabled,
  `NVreg_EnableGpuFirmware=0`.
- `pkgs/qwen38-sm75/bench-one.py` + `qwen38-sm75-bench`: client-side decode
  rate, speculative acceptance (per-position) and prefix-cache deltas against
  a running server.
- `QWEN_EXTRA_ARGS` in the serve wrapper: experiment-only CLI extension for
  A/B runs; never set by the unit.

## Measured (2026-09-16, pinned package, live A/Bs)

All arms: single request, greedy, `ignore_eos`, KV 5.5 GiB, 262 144 max len,
280 W (manual; the unit now persists it). Prompt sizes are real token counts
from the server's `prefix_cache_queries` delta.

| arm | decode @2k tok | decode @8k tok | notes |
|---|---|---|---|
| MTP4, no RHT butterfly | 82.1 / 86.6 @6k, 50.0 @32k | | control |
| **MTP4 + RHT butterfly (kept)** | 86.4 | 75.5 | **+5.5% @6k, +3.5% @32k**, identical acceptance |
| MTP3 + RHT | 83.7 (acc 3.28) | 70.4 (acc 3.08) | MTP4 wins at C1: +3.2% / +7.3% |
| MTP4 + RHT + W4A8 int8 MLP | 28.9 no-spec (acc 2.9 with spec) | 26.3 no-spec | step rate -1.9%, **prefill +14%** (8k TTFT 9.39 -> 8.06 s), acceptance 3.5 -> 2.9 |
| DFlash2 k=7 (needs <=3.2 GiB pool) | 48.6 (acc 2.33) | 42.5 (acc 2.30) | **closed negative** on this package: acceptance collapses after position 1 (76/47/7/6 of 110) |

Decisions taken from this window:

- RHT butterfly: keep (it is in the patch series).
- MTP depth: stay at 4. Campaign X's k=3 result was a C4 Marlin-tile
  geometry result; with the native sm75 partials MTP4 wins at C1.
- W4A8 int8 MLP: not enabled by default. It is a prefill-heavy profile
  (cold long prompts), not a chat default, because it costs ~20-25 % decode at
  short context through acceptance once speculation is on. To try it:
  `VLLM_MARLIN_INPUT_DTYPE=int8` plus
  `VLLM_MARLIN_INT8_INCLUDE_RE='\.mlp\.(gate_up|down)_proj'`.
- DFlash2: closed. The 0.28 native drafter boots with the fp16 patches but
  drafts to ~2.3 tokens/step against MTP4's ~3.4-3.5, and it does not fit the
  262k / 5.5 GiB pool (OOM at 704 MiB).


## Status (2026-09-16, end of window)

- **Deployed and live**: runtime rebuilt with the RHT butterfly + SSE/stall/
  completion-log patches; two-stage warmup; `--sse-keep-alive-interval 30`;
  `VLLM_ENGINE_STALL_SENTINEL_S=120`; 280 W power unit; proprietary NVIDIA
  module with GSP disabled (reboot done, `EnableGpuFirmware: 0`, no Xid this
  boot). Production bench after the reboot: **85.6 tok/s @2k, 75.6 @8k**,
  acceptance 3.51 / 3.40, TTFT 2.35 / 9.35 s.
- **Optional uncensored model**: prepared at
  `/data/qwen38-uncensored/models/uncensored` (pinned
  `leminkozey/Qwen3.8-27B-Uncensored-W4A16-AutoRound` revision
  `f958acb153eb8c7bbd25638149c8c75185559226`, 16 files, size+SHA-256 verified,
  manifest `models/uncensored-manifest.json`). Start it with
  `systemctl start tiberius-qwen38-uncensored` (Conflicts stops the production
  engine first; port 8082, served name `qwen3.8-27b-uncensored`). Measured:
  **58.7 tok/s @2k, 48.1 @8k**, acceptance 3.17 / 2.81 - about 30 % below the
  fast variant because its lm_head/embed are int8 and its MTP head is bf16
  with the full 248k vocabulary. Closing that gap means requantizing its own
  lm_head/MTP (upstream `prepare/quant_*.py` calibration) and building a draft
  vocabulary from its outputs; the model is coherent (17x23 -> 391).
- **Host-memory lesson**: the 7.5 GiB host cannot load a 16 GiB engine while a
  17 GB HF download runs; both a downloader and one engine boot were OOM-killed
  in that combination. Downloads now run as a transient unit capped at 1 GiB,
  and GPU boots are not run next to large downloads.
- **Published as a fork.** The Turing series now lives publicly as
  `carjorvaz/HyperQwen` (branch `turing`), a real fork of upstream HyperQwen
  (formerly `syv-ai/qwen38-27b-rtx3090`) based on the pin this runtime uses. Its
  CI job applies the full series, the 31 upstream patches and these 19, to a
  pristine vLLM 0.28.0 checkout and fails on the first rejection; the first run
  passed. The fork's copies carry a prose header per patch and are otherwise the
  same hunks as the local copies that used to live in `pkgs/qwen38-sm75/patches/`.

  **Moved to a single source of truth (2026-09-19, later window).** The package
  now fetches only the fork, at a rev that pins both series, and the local patch
  directory is gone: `default.nix` holds the revision, `prepare-runtime.py`
  reads `patches/` plus `patches-turing/series` from it, and the revision feeds
  the runtime identity through `QWEN_SOURCE_REVISION`. Verified before deploying:
  the fork's full stack applied to a pristine vLLM 0.28.0 wheel reproduces the
  deployed runtime byte for byte, except the three staged experiments that only
  ever lived in the live venv (the adaptive verify block, the draft window, the
  tile tunables), all of which were inert by default and are now dropped.
- **Campaign complete, remaining work parked**: see *Parked work (resume
  recipes)* below for the uncensored requantization, sub-4-bit trades, the 0.29
  rebase, the Xid bisect arms, a prefill rewrite and concurrency.

## Parked work (resume recipes)

The performance campaign is complete: decode sits at the weight-read floor,
prefill attention at 60-70% of the sm75 ceiling, speculation past k=4 is
measured out (static and adaptive), and the quantization stack costs ~1.3%
relative against an unquantized model. The items below are deliberately not
scheduled. Each carries its recipe, expected effect and evidence so it can be
picked up cold without re-deriving anything. Measured results behind them live
in `docs/VALIDATION.md`.

### Uncensored lm_head and MTP requantization

*Parked 2026-09-19, only worth doing if the uncensored model is actually used.*

The uncensored build is coherent but ~8% slower than the fast variant
(89.7 tok/s @8k, 82.7 @32k, acceptance 3.31/3.51) because its lm_head/embed are
int8 and its MTP head is bf16 over the full 248k vocabulary. The hybrid draft
head (`hybrid-dv8-mtp4c`: int8 40k draft head + int4 MTP) already recovered
most of the gap and is what the uncensored unit last served; what remains is a
GPTQ-calibrated int4 lm_head plus a draft vocabulary built from the uncensored
weights' own outputs.

Recipe: `pkgs/qwen38-sm75/prepare-uncensored.py` prepares the checkpoint (it
prints `Already ready` and exits when nothing is stale),
`pkgs/qwen38-sm75/build-draft-head.py` builds the 40k draft head (bits=8 was
used; bits=4 is the untested arm), and upstream's `prepare/quant_lm_head.py`,
`quant_mtp.py` and `build_draft_vocab.py` are the calibration path against the
uncensored weights; the RTN int4 alternative needs no calibration data. Validate
with the quality battery (GSM8K n=200 plus the PPL pairs) and the 8k/32k decode
pair. The bar to beat is 89.7 tok/s @8k at GSM8K 96.5 / PPL 10.94.

### Sub-4-bit weights or KV

*Parked on quality grounds, not feasibility.*

3-bit weights are worth roughly +25% decode at every context, and 3-bit KV
frees ~1.4 GiB (enough for longer verify blocks), but the quality budget is
real and small: the 4-bit KV cache costs +0.32% perplexity against float16 on
the same pool, and the W4A16 weights are already ~1 IFBench point below the
unquantized model. Anything below 4 bits spends measurable quality for gains
the lossless work could not find either. Revisit only as a *profile* with its
own manifest (the int8-activation variant is the documented middle ground at
+0.9-2.2% PPL), never as a replacement for the W4A16 path.

### vLLM 0.29 rebase

*Parked until upstream moves; no functional gap is open.*

The runtime is pinned at 0.28.0 with 19 local patches, and the fixes worth
having (SSE keep-alive, engine stall sentinel, completion log) were backported
and verified byte-identical to upstream's newer versions. Upstream has also
fixed a glob-vs-`series` patch-ordering trap our local set would otherwise hit.
Recipe: bump the pinned revision in `default.nix`, run `prepare-runtime.py` (it
reports "Expected 31 upstream patches", applies `source/patches/series` in
order, then the sorted local patches), re-run the full validation, and re-check
the two results that depend on upstream behaviour: V2 fused draft capture
(parity when last measured) and the adaptive verify block (measured to lose;
its design notes stay in this file).

### Xid 45 bisect arms

*Parked 2026-09-19: no stability soak is needed. The watchdog stays armed and
the incident notes stay outside the repo.*

The fault class has not reproduced in ~1500 requests across several soaks. If
it returns, the bisect arms are: 250 W instead of 280 W, speculation disabled
(`K=0`), async scheduling off, and the tiled prefill kernel off
(`VLLM_TURING_PREFILL_TILE=0`) -- each booted twice per the A/B protocol above,
with `tiberius-gpu-xid-watch.service` recording rather than reacting. Useful
calibration from 2026-09-19: an engine fault does raise an Xid on this card (a
deliberately broken experiment's illegal memory access produced Xid 31, GPU MMU
fault), so a zero-Xid soak is evidence rather than a blind instrument.

### Prefill kernel beyond the Cutlass template

*Parked: the remaining tail gap is template-shaped, not tuning-shaped.*

Tail prefill runs at 32 TFLOPS effective -- 60-70% of what fp16 with fp32
accumulation reaches on sm75 -- and the tile constants are already the right
ones (see the closed list). The next step is a different kernel family
(hand-written smem attention, or fp16 accumulation with an error bound): a
rewrite whose plausible ceiling is +20-30% on the 8.5 s cached turn at 248k.
The int4 routes stay closed: an int8 prefill needs an unquantized KV whose
Triton s8 dot will not lower on sm75, and the fp16 fallback exceeds its error
budget by 4405x on the rotated int4 layout.

### Concurrency and multi-sequence serving

*Parked: one user, and the earlier C1 measurements stand.*

Every throughput knob is tuned for `max-num-seqs=1`. Serving several streams
needs a second KV pool (the 262k configuration needs 5.97 GiB beyond what the
card has spare) or a shorter context; the wall-clock fallback is the uncensored
engine as a second service on port 8082.

## A/B protocol (remaining arms)

Every arm boots twice: a first boot with no checks (warm the compile cache),
then measurement. Production is stopped for the arm and restored afterwards
(`systemctl stop/start tiberius-qwen38.service`), or the arm runs on a spare
port with production stopped when the knobs cannot be overridden per-request.
Report `qwen38-sm75-bench` decode + acceptance at 8k/32k/128k and the
128-case agent suite for any candidate that must win on quality, not just
speed. Record each number with its prompt/output lengths.

| # | arm | status |
|---|---|---|
| 1 | RHT butterfly | **measured, kept** (+5.5 % @6k, +3.5 % @32k) |
| 2 | W4A8 int8 MLP | **measured**: +14 % prefill, -1.9 % step; profile-only, not default |
| 3 | MTP depth | **measured**: MTP4 beats MTP3 at C1; closed |
| 4 | async scheduling | **measured on the current package: neutral** (86.7 vs 85.6 @2k, 75.7 vs 75.6 @8k); the fork's -16.7 % did not transfer, keep async on |
| 5 | DFlash2 | **measured/closed** (acceptance 2.3) |
| 6 | GDN decode | open: profile `fused_sigmoid_gating_delta_rule_update_kernel` |
| 7 | uncensored requant | open: int4 lm_head/MTP + draft vocab for the uncensored weights, if it is kept |

## Decode-step profile (2026-09-16)

A decode-only window on the current package (2k prompt prefix-cached, 256
tokens out, MTP4, torch profiler, 74 steps) decomposes GPU time as: target +
drafter Marlin W4A16 GEMMs **~75 %**, attention split-KV partials ~7 %,
elementwise/reduce/copy ~10 %, **GDN decode ~2.6 %**
(`fused_sigmoid_gating_delta_rule_update_kernel` 65 ms + causal conv 14 ms of
2.876 s), all RHT variants ~0.7 %, KV dequant/reshape ~0.5 %. So campaign X's
12.4 % GDN figure was a C4/fork property, not this runtime's: a Turing GDN
decode kernel is **not** worth it here, and the biggest remaining lever was the
compiler, not a kernel.

`mode=VLLM_COMPILE` (with `FULL_AND_PIECEWISE`; the GDN backend cannot do FULL)
then measured **95.0 tok/s @2k and 98.5 @8k against 85.6/75.6 with `mode=NONE`**
(+11 % / +30 %), with lower or equal prefill TTFT, identical flags and the RHT
butterfly in both arms. Warm-cache boot: `torch.compile 3.9 s`, engine init
69 s cold / ~17 s warm. It is now the service default; a fresh compile cache
costs about a minute of extra startup.

## Uncensored speed gap: what it is not

The gap is not fixable by grafting the production fast-variant MTP onto the
uncensored checkpoint: the fast MTP is int4-packed with a separate 40k
`mtp.draft_lm_head` and fused projection names, while the uncensored MTP is
bf16 with native per-projection names and no draft head. Closing it needs the
upstream calibration path (`prepare/quant_mtp.py`, `quant_lm_head.py`,
`build_draft_vocab.py`) against the uncensored weights, or an RTN int4
requantization of its lm_head/MTP plus a fresh draft vocabulary.

## Long-context lifecycle, quality and the uncensored hybrid (2026-09-16, later window)

**262k lifecycle, production server, new runtime** (VLLM_COMPILE + RHT), five
phases, all pass, zero preemptions:

| phase | prompt tokens | result |
|---|---|---|
| cold near-limit | 248,098 | correct middle-fact retrieval, 683.1 s |
| cached continuation | 248,099 | 246,432 cached (99.3 %), correct end-fact, **8.8 s** |
| unrelated replacement | 200,074 | correct fact, 487.1 s (old prefix evicted) |
| zero-cache recompute | 248,098 | correct, 685.1 s, 0 cached |
| short prompt | 27 | 0.34 s |

Post-cycle: `NRestarts=0`, no Xid, GPU back at 280 W, host RAM/swap stable.

**Quality battery** (upstream `bench/quality_battery.py`, same server): PPL
en 10.8077 / da 10.9380 / all 10.8797 (25,092 tokens), GSM8K n=200 **94.5 %**,
mean 377 tokens. The published stack reads GSM8K 95.0-96.5 with an SE near
1.5 pt at n=200, so this is inside the band and not a measured regression.

**Uncensored hybrid.** The 40k draft head built from the uncensored int8
lm_head (`build-draft-head.py`, bits=8) lifts the uncensored model from
58.7/48.1 tok/s (pre-compile) to **79.3/60.2 tok/s at 2k/8k with acceptance
preserved** (3.36/2.84 against 3.17/2.81). The target's int8 lm_head and bf16
MTP still cost it the rest of the gap to the fast variant (95/98.5). The
uncensored unit now serves `models/hybrid-dv8` with `MTP_DRAFT_VOCAB=1`.

**Blocked: int4 MTP requantization.** Requantizing the nine MTP matrices to
int4 (and using an int4 draft head, mirroring the fast config) fails vLLM's
loader with a packed-weight concat mismatch (`1280` vs `640`): the `^mtp\..*`
group also claims the tied `mtp.embed_tokens`, whose weights come from the
target's int8 embedding. Narrowing the group leaves a shape assertion in
`load_column_parallel_weight` on the draft head group instead. Left open.

**Two gotchas added to the list.** `cp -al` hard-links the config/index files,
so an in-place `write_text` in the source directory mutates the base checkpoint
too - the builder now writes atomically (`os.replace`) and the base has a
prepare-time hash/stamp check that repairs it. And `systemd-run` + a wrapper
that reads `/proc/<pid>/environ` dies under `pipefail` when no server is
running; source the LD_LIBRARY_PATH from the Nix wrapper instead.

**Uncensored hybrid, validated and finished.** The uncensored option now
passes the same gates as production: quality PPL all **10.94** (25,092
tokens) and GSM8K **96.5 %** (n=200), and a 100k lifecycle 5/5 (cold 100,098
tokens in 175 s, cached 97,920 tokens in 5.98 s, replacement, cold recompute
176 s, short 0.24 s, zero preemptions). Its validation window needs a smaller
pool than serving: at the unit's 4.5 GiB KV the quality harness OOMs on
`prompt_logprobs` (the int8 lm_head leaves no scratch), so it ran at 3 GiB /
145k max len.

Draft-head/MTP evolution (2k/8k tok/s, acceptance in brackets): original
58.7/48.1 (3.17/2.81) -> int8 head + bf16 MTP 79.3/60.2 (3.36/2.84) ->
**int8 head + int4 MTP 88.5/68.9 (3.36/2.90), shipped** -> int4 head + int4 MTP
72.1/66.2 (2.66/2.75), worse: the int4 head's 12.9 % weight error costs more
acceptance than the halved read saves. The unit serves `hybrid-dv8-mtp4c`
(`MTP_DRAFT_VOCAB=1`); against production's 95/98.5 the remaining gap is the
target's int8 full-vocabulary lm_head read on every verify step.

Two builder bugs found and fixed while getting there. `dict(group,
num_bits=...)` wrote the bit width at the group's top level instead of under
`weights`, so the MTP layer stayed int8-shaped while the tensors were int4 (the
loader asserted `(5120, 2560)` against `(5120, 1280)`); and the shipped
`re:.*lm_head$` target also matches `mtp.draft_lm_head`, so an int4 head is
silently expected at int8 width unless that target is narrowed (negative
lookahead). Both are fixed in `build-draft-head.py`.

**First-request JIT compiles: closed.** On the current production boot all 30
`JIT compilation during inference` warnings fall inside the warmup window
(2 m 22 s) and **zero** occur afterwards, including through the 248k lifecycle;
the earlier counts came from scratch servers that skip the warmup. No change
needed.

**Deferred with reasons:** the attention `nseg` sweep needs a new env in the
Turing patch and three reboot cycles for an expected <=2 %; the upstream pin
bump is a rebase of 13 local patches onto 40 upstream ones whose valuable
pieces (int64 block-id casts, series ordering, mamba retirement, observability)
are already backported.

## Rollback

Runtimes are immutable generations under `/persist/qwen38-sm75/runtimes`; the
prepare service re-links `venv` only after a successful patched install, so a
bad series leaves the previous generation in place. The driver change needs a
reboot and a console for rollback; boot with the previous systemd-boot
generation if the proprietary module does not load.

## Long-context campaign (2026-09-17)

Long-context decode was attention-bound, not GEMM-bound: a 64k decode profile
showed the split-KV partial kernel at ~58% of the step (`partial_kernel`
451 ms + `qwen38_turing::partial` 95 ms of a 684 ms window; Marlin ~30%). The
kernel staged each packed-int4 K/V element with a scalar byte load (two lanes
reading the same byte, ~16 useful bytes per warp transaction), leaving it
latency-bound at ~27 GB/s effective. `patches/turing-spec-staging.patch`
vectorizes the staging: each lane loads two 4-byte words of one row and stores
16 halves, warp-contiguous across two 128-byte rows per instruction. The
attention reference suite (fp32 comparison and live CUDA-graph replay) passes.

| prompt | before | after | delta |
|---|---|---|---|
| 2k | 95.1 | 100.3 | +5% |
| 8k | 98.5 | 110.6 | +12% |
| 32k | 50.3 | 74.6 | +48% |
| 64k | 42.9 | 72.6 | +69% |
| 128k | 24.0 | 49.1 | +105% |

Follow-ups measured in the same window:

- **MTP depth at long context**: k=5 (61.6 at 64k) and k=6 (59.2) both lose to
  k=4 (62.5): each extra draft pass costs ~2x a target layer's attention, more
  than the acceptance it buys. MTP4 stays.
- **ngram_gpu** (`method: ngram_gpu`, k=7, lookup min/max 2/8) on the verbatim
  copy task at 32k: acceptance 4.4, 100+ tok/s against MTP's 3.5 / 82; on chat
  prompts acceptance collapses to ~1.1 (~29 tok/s). Shipped as the documented
  copy-mode `serve.env` profile.
- **int8 MLP activations**: +8-10% TTFT at 32k/64k, ~10% slower steps; stays a
  toggle, not the default.
- **nseg** 16/64/128 at 32k/64k: no effect (50.3/36.2 baseline, 59.5-51.3 and
  36.6-36.7 with acceptance taken into account); superseded by the staging
  fix.
- **Prefill** is unchanged and GEMM-dominated; its remaining levers are the
  int8 profile above and, at 50k+, an int8-QK prefill attention kernel.
- The MTP + prompt-lookup **hybrid** (llama.cpp's `draft-mtp,ngram-mod`, which
  reports 74-token mean chains and 129 -> 140 tok/s at 90k) has no vLLM
  equivalent; upstream's chain patch is DFlash2-specific. Porting the lookup
  idea to the MTP speculator is the largest remaining project.

Copy-mode tuning (same window): the prompt-lookup match window (min/max 2/8 vs
16/64) does not change acceptance on the verbatim task (4.435 either way), and
a 16-token verify block (k=15) is infeasible on Turing: the proposer/attention
kernel requests 81,920 B of shared memory against the 65,536 B limit, the same
wall as the campaign's native int4 prefill attention. Copy mode therefore stays
at k=7 (8-token blocks, ~100 tok/s on the copy task against MTP's 82).

### MTP history lookup: built, measured, shipped

The last bullet above is now done, on the V1 runner rather than by porting
upstream's DFlash2 speculator (the V2 runner also has an MTP speculator with
the LABD lookup, but V2 MTP measured 9-19% slower than V1 MTP on chat at the
same acceptance, so the runner was left alone).

Design (`patches/turing-mtp-history-lookup.patch`, three files):

- `update_lookup_history` keeps each request's token history in a device
  buffer, appended from the authoritative `sampled_token_ids` (accepted draft
  prefix plus bonus) by a one-program-per-request Triton kernel. The input
  batch's CPU token buffer is only read for the initial prompt: it lags the
  sampler by one token, which silently misaligns any history built from it.
- `_lookup_propose` calls upstream's `suffix_lookup` over that history and, when
  the match is long enough, returns the continuation as the whole draft block
  and skips the drafter's forward pass entirely.
- The skip decision is read from pinned memory that earlier steps filled with
  asynchronous copies, so the host never waits for this step's kernel -- a
  first version that synced per step cost 5-20% of chat decode by breaking the
  async-scheduling overlap.
- Gates: greedy batches only (the proposal carries no draft distribution, which
  is lossless exactly where the rejection sampler ignores it), a match of at
  least `VLLM_MTP_LOOKUP_MIN` (default 24) tokens, and a previous step that
  accepted every draft it was given. Without the last two, coincidental matches
  in filler text start chains whose drafts are wrong and acceptance falls.
- `suffix_lookup` grew a `min_tail` argument (default 0 = upstream behaviour).
  With the most-recent tie-break, a nearby repeat that has three tokens left
  wins against the copy it is a repeat of; the MTP caller asks for `min_tail=k`
  so only matches that can fill a whole block are considered.

Measurements (same runtime and host, chat sizes are the filler prompt, copy is
the verbatim-reproduction task):

| task | MTP | MTP + lookup |
| --- | --- | --- |
| 2k chat | 90.4-92.2 | 90.4-92.0 tok/s |
| 8k chat | 88.3-89.2 | 89.2-90.3 tok/s |
| 32k chat | 76.1 | 76.1 tok/s |
| 64k chat | 68.3 | 68.4 tok/s |
| 128k chat | 57.3 | 57.9 tok/s |
| 32k copy | 97.5 / 91.0 | 98.2 / 93.8 tok/s (exact) |
| 60k copy | 78.4 | 89.7 tok/s (exact) |
| GSM8K | 94.5% | 94.5% (n=200) |

So: free on chat, +14.4% on long copy, and the 32k copy result is a wash
because the drafter already scores ~4.0 acceptance there. Enabled in the unit
environment; the absolute numbers are ~10% below the morning's baseline on the
same host for reasons outside this patch (both runtimes, both governors, and
the lookup-off arm reproduce today's numbers).

Remaining ideas, in order of expected value: a *fused* mode that runs the
drafter and keeps the lookup only where the two agree (upstream's `fuse_draft`
kernel: no skip, so no acceptance risk at all, but pays the drafter), a
`VLLM_MTP_LOOKUP_MIN` sweep between 12 and 32, variable verify length driven by
the match, and the int8-QK prefill attention (`VLLM_PREFILL_ATTN=int8` already
exists upstream but was worth only +0.4% in upstream's own config).

V2 runner check (why the lookup was ported to V1 instead): upstream's LABD
lookup lives in the V2 speculator (`v1/worker/gpu/spec_decode/dflash2/lookup.py`
plus `VLLM_DFLASH2_CHAIN`), and V2 already has an MTP speculator, so
`VLLM_USE_V2_MODEL_RUNNER=1` with `method: mtp` was the obvious home. Same
runtime, same host, same acceptance:

| prompt | V1 MTP | V2 MTP |
| --- | --- | --- |
| 2k | 100.3 (morning) / 90.6 (today) | 90.3 |
| 8k | 110.6 / 88.8 | 89.5 |
| 32k | 74.6 / 75.7 | 76.2 |
| 64k | 72.6 / 67.9 | 65.9 |

V2 is at or below V1 everywhere except 32k, so the port went into the V1 MTP
proposer and reuses only the lookup kernel from the V2 tree.

### Sampled traffic: what the agent actually gets (and what that changes)

Everything above was measured in greedy mode. The production client (OMP) sends
no sampling parameters, so the server applies the model's
`generation_config.json`: `temperature` 1.0, `top_k` 20, `top_p` 0.95 (verified:
two identical requests return different text). That changes the picture:

| task | greedy | sampled (temp 1.0 / top_k 20) |
| --- | --- | --- |
| chat acceptance, per step | 3.1-3.25 | 3.19-3.23 |
| chat per-position acceptance | 0.79 / 0.63 / 0.40 / 0.30 | 0.84 / 0.63 / 0.41 / 0.30 |
| copy 32k, exact | 98.2 tok/s, acc 4.03 | 97.8 tok/s, acc 4.03 (`copy_exact` still true) |
| copy 60k | 90.7 tok/s, acc 4.06, exact | 77.5 tok/s, acc 3.65, **not exact** |

Consequences, all measured rather than assumed:

* `k=4` is still the right depth: the per-position decay is
  indistinguishable between modes, and position 4 still returns ~0.3 tokens per
  step for one extra draft pass.
* `draft_sample_method`: production's `probabilistic` beats `greedy` on sampled
  traffic (3.23 vs 3.01 acceptance), because a dense draft q gets
  `min(1, p/q)` acceptance while a point-mass draft only gets `p(x)`.
* That is also why the history lookup must stay greedy-only: on the 32k copy
  task the lookup's point-mass fills score 3.82 against the probabilistic
  drafter's 4.03. The knob `VLLM_MTP_LOOKUP_SAMPLED=1` exists to re-run that
  A/B; the default is 0. Upstream gates its own drafter-free chain the same way.
* A prefill chunk of 4096 tokens does not fit in 22 GiB (out of memory with 110
  MiB requested and 117 MiB free), so 2048 is the ceiling and there is no
  chunk-size headroom left; int8-QK prefill attention is a no-op here
  (54.4 s vs 54.2 s at 64k, 151.5 s vs 151.2 s at 128k).

Next projects, in the order their measured payoffs justify:

1. **Variable verify length driven by the lookup.** A hit currently fills only
   `k` slots, so a greedy copy tops out at 5 tokens/step. The target forward
   costs the same weight reads for q=5 and q=17; only attention grows, so a
   16-token history fill would be worth ~6 tokens/step in *sampled* mode too
   (sum of per-position acceptance over 16 positions at the measured decay),
   and 17 in greedy. Plumbing: `SchedulerOutput.num_spec_tokens_to_schedule` is
   one int per step, so the scheduler needs a hint from the previous step's
   probe (the ngram_gpu path already returns per-request valid counts, and
   `_spec_attn_qmax`/`VLLM_SPEC_DECODE_ATTN_QMAX` plus
   `max_cudagraph_capture_size` gate the q=17 verify shape; the partial turing
   kernel's `kRows=32, qt=32//G` already covers q<=32). `min_tail=k` in
   `suffix_lookup` then has to follow the scheduled block.
2. **Interactive long-context latency.** A cached continuation at 248k still
   costs ~8.8 s because the uncached tail attends over the whole context
   (2048 q against 248k kv), which is why the tail prefills at ~230 tok/s while
   a cold 248k prefill runs at ~363 tok/s. The levers are a long-q prefill tile
   and int8-QK scores; both need measuring before they are worth porting.
3. **Sub-4-bit KV.** Attention is 20-30% of a long-context step, and this pin
   has no KVarN: a 3-bit K with per-channel scales would cut attention traffic
   ~25% and grow usable context 30-50%. New kernel, not a port.

### Interactive latency, the decode floor, and two new tools

Cached continuations are where a long-context agent lives, so the tail was
measured directly (prefix cache warm, 8-token replies, appending a fresh tail
to a cached prefix): 624 tok/s at 32k of context, 549 at 48k, 464 at 64k, and
~240 at 248k, which is exactly the 8.5 s cached turn in the lifecycle check.
The tail is scored against every key in the context, so this is a
long-context *attention* cost, not a scheduling one, and the int8-QK prefill
attention is inert here too (under 0.2 s over the whole sequence).

Decode is at the weight-read floor: the W4A16 target reads ~13-14 GiB per step
(~23-25 ms at the card's effective bandwidth) and a 2k step measures ~35 ms at
acceptance 3.17. Every remaining decode percent has to come from acceptance or
from compressing the weights/KV further; kernel micro-tuning is spent.

Two tools are now part of the package so these numbers can be reproduced:
`qwen38-sm75-copy-bench` (verbatim-reproduction drafting bench, with sampling
controls) and `qwen38-sm75-sample-probe` (acceptance, per-position acceptance
and throughput under default sampling). Measurement hygiene learned the hard
way: `bench`/`soak` use a repeated-word filler (a stable repetition workload,
not chat), the warmup service depresses readings by 10-15% while it runs, and a
health poll after a restart can answer from the old process -- wait for the
unit's MainPID to change first.

- **Prefill tile constants, swept rather than assumed** (the loader's
  constants were made env-tunable in the live runtime, with today's values as
  defaults; discarded at the next prepare, and the harness that applies it is
  kept in the repo as `pkgs/qwen38-sm75/tile-sweep.py`). warpN=32 does not
  compile, warpN=128 is 5x slower on both the 64k and 256k shapes (register
  spills break the load iterator), and minBlocksPerSm=2 gains 3% at 64k and
  nothing at depth. The
  shipped constants were already right: at 32 TFLOPS effective the kernel runs
  at 60-70% of the sm75 fp32-accumulate ceiling, so the tail is bound by the
  Cutlass template, not by its constants.
- **Draft attention window** (live-only, off by default, discarded at the next
  prepare). The depth-dependent ~3.2 ms of the draft chain is the drafter
  attending over the whole context, which is wasted on a local prediction, so
  windowing it to 4096 tokens looked like +7-15% at depth with exactly correct
  outputs. It is not viable here: the windowed spec-attention path is ~25%
  slower per step at 8k (44.9 ms against 35.8 ms) and raises an illegal memory
  access at 64k (Xid 31, GPU MMU fault) because the staged int4 spec kernel
  indexes the block table assuming the full-causal layout. Corollary worth
  keeping: an engine fault does raise an Xid on this card, so the zero-Xid soak
  readings are real evidence rather than a blind instrument.

## Closed for this configuration (measured, do not retry)

* **A draft block longer than k=4**: raising `num_speculative_tokens` to 15 needs
  ~0.5 GiB more KV budget (5.97 against 5.5 GiB at 262144 max len), because the
  lookahead slots and the int4 spec scratch are accounted inside the pool. With
  262k context there is no room; at 235k it would fit at the cost of context.
  The lookup's long-block idea therefore stops at 5 tokens per step for greedy
  copy work.
* **int8-QK prefill attention**: it is gated on an *unquantized* KV cache
  (`not is_quantized_kv_cache(self.kv_cache_dtype)`) and on FA2, which SM75
  cannot run; the Triton kernel quantizes fp16 K on the fly, so it cannot read
  our per-token-head int4 cache at all. The int4 KV cache is what buys 262k
  context on a 22 GiB card, so this lever is structurally incompatible with the
  configuration, not merely unwired: measured inert in both the cold and the
  tail regime (under 0.2 s over 25-69 s runs).
* **Prefill chunks of 4096**: 110 MiB allocation against 117 MiB free.
* **`--draft_sample_method greedy`**: 3.01 sampled acceptance against 3.23 for
  probabilistic drafts -- a dense q gets `min(1, p/q)` where a point mass only
  gets `p(x)`.
* **V2 model runner with MTP**: below V1 at every size except 32k.

### Next projects, with their measured justification

1. **int8-QK prefill for the Turing tile kernel.** The tail a cached turn pays
   for is the score GEMM against every key in the context, and the upstream
   int8 path measures 1.35x FA2 at kv=51200 and +5.3% end-to-end prefill at
   51k -- but it is wired into the FA2 backend only, which SM75 cannot use.
   That port would have to dequantize our int4 K first (the upstream kernel
   quantizes fp16 K on the fly), i.e. write an s8-mma variant of
   `turing_prefill_tiles.cu` (the fp16 tile that already keeps its accumulator
   in registers is the scaffold) that unpacks the packed int4 cache in the
   kernel, mean-smooths K per (head, d) into int8 scratch, applies per-64-key
   scales and accumulates in fp32. It is the only remaining lever that targets
   the *interactive* case the user hits every turn (8.5 s at 248k), but it is a
   new kernel rather than a port. Quality gates: the 248k lifecycle retrieval,
   GSM8K 94.5% and PPL 10.88.
2. **Fuse the k draft passes into one CUDA graph.** At 8k a step is ~35 ms with
   the target's weight read as the floor, so the draft chain plus sampler is
   ~10-12 ms of launches and small kernels; sampled steps add ~3 ms more. The
   V2 autoregressive speculator in this same tree (`autoregressive/speculator.py`,
   `_fused_multi_step_decode`) is the reference implementation for capturing the
   chain. Expected a few percent at short context, less at depth.
3. **Sub-4-bit KV.** Attention is 20-30% of a deep step and 3-bit K with
   per-channel scales would cut its traffic ~25% *and* free pool memory (which
   is what blocks the longer draft block above). New kernel; no KVarN in this
   pin.

### Concurrency, VRAM headroom, and the upstream refresh (measured)

**A second client cannot share the GPU yet.** With `--max-num-seqs 2` the int4
packed attention kernel asks for 81,920 B of shared memory against SM75's
65,536 B and the engine dies on the first speculative step; the request to lower
the block count came from the tile widening with the *sequence* count, not the
query count, so k=2 (2x3=6 queries) fails the same way. The scratch plan's
capacity is now backstopped at one 16-query program
(`zz-turing-mq3d-scratch-cap.patch`), which is a no-op at `max-num-seqs 1` and
makes the 2D fallback reachable, but the fallback kernel is the one that needs
the 80 KiB tile. Until the kernel is re-tuned to split its tile over sequences,
one sequence is served at a time: a second request queues, and the prefix cache
plus the 30 s SSE keep-alive keep that queue usable (two concurrent 16k streams
measured 84 tok/s aggregate at `max-num-seqs 1`, i.e. the streams serialize at
full single-stream speed).

**KVarN.** It exists upstream as a separate installer (`kvarn/install.sh`,
`kvarn-0.28.0.patch` + `kvarn-v2-runner-0.28.0.patch`) and buys 1.7x the pool,
but upstream's own README prices it at **half the decode rate past ~100k**
(32.0 against 68.1 tok/s at 112k), to be taken when a request would not
otherwise fit. We already run a more aggressive KV than upstream's own tiers
(int4 per-token-head against their `fast` bf16 and `long` fp8), so there is no
free VRAM in KVarN at our decode rates. Where VRAM can actually come from:
the pool/context trade (the pool needs ~22.5 KB per token, so 5.5 GiB holds
262k, 4.1 GiB holds 192k, 2.75 GiB holds 128k), the mamba-align retirement fix
(already in our local set), or a sub-4-bit KV kernel.

**Upstream refresh checked, not needed yet.** Upstream has moved 68 commits
past our pin but is still on vLLM 0.28.0, and the diff in the paths we use is
materially already ours: our `turing-mamba-retirement.patch` is byte-identical
to their new `mamba-align-retire-null-gaps.patch`, our three `zz-upstream-*`
patches are byte-identical to theirs, and the rest is env registration (the
int4-mq3d knobs), an sm89-only fp8 split-KV patch, and CPU-offload work. They
did fix the same glob-vs-`series` ordering trap we would have to handle at the
next rebase, which stays on the list for the 0.29 jump.

**Deployment gotchas worth remembering.** A store path referenced only by a
`/run/systemd/system` drop-in has no GC root, so the nightly `nix-gc` collected
the package under the running service and a restart failed with 203/EXEC; there
is now a root at `/nix/var/gcroots/qwen38-sm75-deploy`. The runtime
preparation must run inside its 3 GiB memory bound (or with the engine
stopped): on a 7.5 GiB host it cannot share RAM with a loaded engine.

### One SM75 wall behind three closed doors (and where the tail really goes)

Three separate "make the batch wider" experiments die in the same place -- an
int4 attention Triton kernel asking for more than SM75's 64 KiB of shared
memory, because the tile grows with the query block:

| experiment | kernel | required |
| --- | --- | --- |
| `num_speculative_tokens 15` (lookup long block) | int4 packed attention | 81,920 B |
| `--max-num-seqs 2` (two clients at once) | int4 packed attention (`_launch_packed_attn`) | 81,920 B |
| `VLLM_INT4_MQ_3D=1` (the campaign's multi-query 3D path) | int4 packed attention | engine dies at the first spec step |

They are one project, not three: re-tile the kernel so a program's shared
memory does not grow with the query block (split the query block across
programs, or shrink the key tile), and all three reopen. Until then the cap in
`zz-turing-mq3d-scratch-cap.patch` keeps the 2D fallback reachable, and the
service serves one sequence with k=4.

**The prefill tail is compute-bound and nearly done.** A local microbenchmark of
the serving path (`prefill_bench.py`, no server needed) splits the paged-int4
gather from the attention:

| kv | q | run | gather | attention |
| --- | --- | --- | --- | --- |
| 16k | 2048 | 31.6 ms | 0.23 ms | 31.4 ms |
| 64k | 2048 | 100.7 ms | 0.92 ms | 99.8 ms |
| 128k | 2048 | 203.4 ms | 1.84 ms | 201.5 ms |

The gather that the vectorized-staging lesson suggested would be a bottleneck is
1-3%: the tail is the attention, at a steady ~16.6 TFLOPS of score GEMM (33
TFLOPS counting softmax and PV) -- roughly 60% of the sm75 fp16/fp32-accumulate
ceiling. There is no lossless tile win of the size the campaign found in the
decode path; the remaining tail levers are int8 scores (the upstream path
cannot read int4 KV, so this is a dequant-in-kernel s8-mma variant, cos >
0.99999 by their measurement) or a mask-free causal path, both kernel projects.

**From z.ai's infrastructure write-ups** (their GLM-5.3 build, plus the
coding-agent-serving post): the transferable parts for a single 2080 Ti are
methodological rather than architectural -- dense, local, cheap, verifiable
feedback (the microbenchmark above is exactly that; their LayerSplit/EPD/
ReplaySSM work is multi-GPU), a `tl.dot` precision audit (we are safe: sm75 has
no TF32, and `FLA_TRIL_PRECISION=ieee` already forces IEEE for the FLA kernels),
and one operational idea worth keeping: speculative acceptance metrics as an
anomaly signal (very low `specacceptlength` with high `specacceptrate` flagged
their corrupt generations). We already record per-position acceptance in
`soak.py`; the thresholds to watch are acceptance below ~1.5 for minutes with
requests in flight.

### The int4 attention was dotting in fp32 -- lossless fix, and what it unblocks

The packed-int4 Triton attention dequantized its nibbles to fp32 and dotted
them there. On sm75 an fp32 `tl.dot` has no tensor cores to run on, and the
fp32 K/V tiles are also what the 64 KiB shared-memory limit was counting. Since
the unpacked nibbles are integers in [0, 15] -- exact in fp16 -- and the
per-token-head scales and zero-point corrections stay in fp32, casting them to
the query dtype is numerically identical while halving the tiles
(`zz-turing-int4-fp16-dots.patch`; the P operand of the P@V dot also moves to
fp16, the standard flash-attention arrangement).

Consequences, measured:

* `VLLM_INT4_MQ_3D=1` -- the campaign's multi-query 3D path, previously
  unusable on sm75 -- now boots and serves. It measures at **parity** with the
  native path (step times within +-5%: 33.4 against 35.2 ms at 2k, 39.5
  against 39.6 at 32k, 46.5 against 45.7 at 64k), so production keeps the
  native path; the point is that the fallback is no longer broken and no
  longer slow.
* The shared-memory half of the long-verify block's blocker is gone. What
  remains is only the KV pool: every lookahead token costs ~43 MiB of the 5.5
  GiB budget, so `k>4` at 262144 max len still does not fit. `k=8` (a 9-token
  verify block) would need roughly 256k max len -- about 2% of context for
  ~1.8x the tokens per step on greedy copy/edit work. That is the user's call,
  not a blocked experiment.

Also from the z.ai write-ups (full text): their TF32 `tl.dot` bug class cannot
reach us (sm75 has no TF32, our kernels dot int8/fp16, and
`FLA_TRIL_PRECISION=ieee` covers the FLA state kernels), their 1.71x kernel win
came from V-tiling that repeated normalization -- a search we ran across our
own attention kernels without finding an analogue -- and their operational
lesson (speculative acceptance metrics as an anomaly signal) is recorded above.

### Where a deep decode step actually goes (measured, no profiler needed)

By running the same decode with speculation off (`QWEN_DISABLE_SPEC=1`) and on
(k=4), on realistic wikitext at four contexts, the step splits cleanly:

| context | k=0 step | k=4 step | draft chain (4 passes) | share |
| --- | --- | --- | --- | --- |
| 2k | 29.0 ms | 33.5 ms | 4.5 ms | 13% |
| 8k | 29.9 ms | 36.2 ms | 6.3 ms | 17% |
| 32k | 33.5 ms | 39.5 ms | 6.0 ms | 15% |
| 64k | 38.0 ms | 44.8 ms | 7.7 ms | 17% |

At 64k that closes: ~24 ms of weight reads (the W4A16 floor), ~7.7 ms of draft
passes, ~5 ms of split-KV verify attention (the vectorized-staging path; ~0.65
ms per full-attention layer), ~1 ms of int4 KV traffic, and the rest GDN,
sampler and host. The fp16 int4 fix is worth ~2% at 64k and nothing at 128k,
because the decode attention was never the depth bottleneck; the tail prefill
is (see the microbenchmark above), and int8 scores are closed on sm75 (the
upstream kernel cannot even be lowered: Triton's TTGIR pass fails on its s8
dot at every tile size, its fp16 mode is numerically wrong for this rotated
int4 layout, and usable tile sizes exceed 64 KiB of shared memory -- the third
int8-attention dead end after the FA2-only wiring and the unquantized-KV gate).

Consequences for long context, in order of measured value:

1. **A longer verify block is the only remaining large long-context gain**, and
   it is a context trade: k=8 (a 9-token block) needs roughly 256k max len for
   ~1.8x tokens per step on greedy copy/edit work. The kernel side is ready
   (the shared-memory half of the blocker went with the fp16 fix).
2. The fused draft capture targets 4.5-7.7 ms of every step (13-17%), so its
   ceiling is ~6-12% at short and mid context and less at depth.
3. Everything else is at its floor: weights dominate the decode, the tail
   prefill runs at ~60% of the sm75 fp32-accumulate ceiling with the gather at
   1-3%, and the profiler cannot dump traces in this build (CUDA graphs or
   eager), so microbenchmarks like `prefill-bench.py` remain the instrument.

### Client sampling is now logged, and two more projects closed by measurement

**The sampling log is live** (`zz-turing-sampling-log.patch`): one INFO line per
request with the source address, a prompt digest, character count, temperature,
top_p/top_k/min_p/seed/n/stream, tool count, reasoning effort and max tokens.
It is read-only and logs no prompt text. Why it matters: the history lookup --
the only feature that changes copy/edit throughput -- serves greedy requests
only, so whether to build more of it depends on what each client actually
sends. `grep 'sampling-log'` on the unit's journal tells you which client is
which and what it sends.

**The fused draft capture is closed.** V2's model runner was re-measured on
realistic text with all of this week's fixes in place and is now at parity with
V1 (step times 34.6/35.7/39.3/46.3 ms at 2k/8k/32k/64k against V1's
34.5/36.3/39.8/46.7, slightly ahead at 8k and beyond). Our TRITON_ATTN backend
advertises `supports_draft_decode_metadata_update = True`, so V2's *fused
multi-step draft decode* was active during that run -- and it gains nothing
over V1's Python draft loop. The draft chain's 4.5-7.7 ms per step is therefore
device work (four MTP-layer forwards), not launch or host overhead, so
capturing it buys nothing in either runner. That cancels the "fused capture"
item that had been ranked first among the lossless decode levers.

**What that leaves.** On decode: acceptance (a model-level property) and the
copy-path long block. On the interactive path: a genuinely better fp16 prefill
attention kernel (int8 is closed three ways, the gather is 1-3%, the kernel is
at ~60% of the sm75 ceiling). On configuration: the k=8 verify block, which is
now the single largest available win -- about 1.8x tokens per step on greedy
copy/edit work for roughly 2% of context -- and it waits only on knowing
whether a client that does copy-shaped work actually samples greedily, which
the log above now records. A static k=8 profile is a one-line change; doing it
adaptively (4 normally, 8-16 after a lookup hit) needs a scheduler-to-runner
handshake, because the scheduler currently fixes k per step from config rather
than from what the proposal found.

### k=8 needs to be adaptive, and only a greedy client pays for it

Static k=8 was measured before building anything (same runtime, realistic text,
`K=8` plus `QMAX=16`, capture size 16):

| context | k=4 step | k=8 step | chat cost |
| --- | --- | --- | --- |
| 2k | 34.5 ms | 40.0 ms | +16% |
| 8k | 36.3 | 44.1 | +22% |
| 32k | 39.8 | 52.3 | +31% |
| 64k | 46.7 | 64.3 | +38% |

Acceptance does rise with the wider block (4.41 at 2k, 4.89 at 32k against
3.79/3.85), but not enough: every step pays four more MTP-layer forwards, and
the verify attention is wider for every request. Copy work gets *worse* too
(68.7 tok/s, acceptance 3.75, against 98 tok/s and 4.03) when the lookup cannot
fill eight slots, because the drafter then runs seven passes to produce four
useful tokens. Two useful facts came out of it: **k=8 boots at the full 262144
context on the same 5.5 GiB pool** (no context trade at all, contrary to the
k=15 estimate), and the native verify path handles q=9 with `QMAX=16`.

So the win exists only in adaptive form: schedule 8 slots for the step *after*
the lookup reports a long match, 4 otherwise. The design, with the pieces this
window verified:

* the proposer already reads the previous step's match length through pinned
  memory, so it can ask for a long block without a sync;
* the ask travels to the scheduler through one new field on
  `ModelRunnerOutput` (`spec_block_hint`); the scheduler uses the configured k
  as the maximum and a base of 4;
* inside that path the batch is greedy by construction (the lookup only serves
  greedy requests), so padded draft positions need no draft probabilities --
  the sampler ignores them -- which removes the fiddly part of the port;
* the drafter's chain is capped at the base k and padded to the scheduled
  width, so a long block is never paid for by seven draft passes.

It is deliberately not built: the win applies to greedy copy/edit clients only,
and the sampling log added the same day is what says whether such a client
exists. Until then the default stays k=4 at 262144.

Quality re-validated on the deployed runtime (after the fp16 int4 change, the
scratch cap, the fp16 verify path and the sampling log): PPL 10.8797 over 25,092
tokens (English 10.8077, Danish 10.938) against the historical 10.88, and GSM8K
94.5% (n=200) against 94.5% -- no drift, which also says the fp16 tensor-core
dequantization is numerically equivalent in practice, not just in argument.

### pi is wired, and the adaptive block is one graph-shape fix from done

**pi is a client now.** `~/.pi/agent/models.json` carries a `tiberius` provider
(`http://tiberius:8080/v1`, model `qwen3.8-27b`, context 262144, temperature 0)
and `auth.json` a placeholder key (vLLM needs none, pi requires one). pi's
thinking levels had to be remapped: this model's template accepts only
`xhigh`, `medium` and `low`, and pi's `high` default was rejected with a 400, so
off/minimal/low -> low, medium -> medium, high/xhigh/max -> xhigh. Verified
end-to-end; the sampling log shows the Mac (`client=100.75.134.73`) sending
`temp=0.0` with a 4197-character agentic prompt and a tool loop.

That settles the adaptive-block question: **pi is greedy**, so the history
lookup applies to it and a longer verify block would pay.

**The adaptive block works but is blocked on the cudagraph stride.** Built and
exercised (four files, gated behind `VLLM_MTP_ADAPTIVE_K`, off by default):
the proposer asks through a new `spec_block_hint` on `ModelRunnerOutput`, the
scheduler keeps the configured k as the maximum and the base k otherwise, an
un-hinted step chains only the base number of drafts and pads the rest, and a
second pipelined probe (run only while a copy is already running) decides
whether a match can fill the whole long block. With the env set, base steps
match the k=4 baseline exactly and the copy acceptance jumped to 4.4 against
3.4 when the long block engaged -- the mechanism is right.

What stops it: the cudagraph machinery carries a single spec stride
(`config_k + 1`), pads to it and asserts on it. Base steps are 5 tokens, long
ones 9, so with the config at 8 the base steps assert; relaxing the stride to 5
instead makes the capture sizes collapse to multiples of 5 and drops the small
shapes everything else uses, which measured slow (8k 80.7 against 97.5, 64k
52.8 against 69.8). Doing it properly means teaching the dispatcher and the
capture sizing about two strides, which is a container-level change and not
something to rush. The code stays out of the repository (so the next switch or
prepare discards it) and is inert in the live runtime without the env -- the
production numbers after the experiment match the k=4 baseline to the millisecond.

**Quality question, answered from the project's own tables.** On IFBench
(prompt-level strict) Qwen's model card reports 79.5 for the unquantized model
and this stack measures 78.3, so the whole W4A16 quantization costs about one
point (~1.5% relative); the fast variant we serve adds an int4 GPTQ lm_head and
MTP for +0.6% perplexity and *better* GSM8K (96.5% against 95.5%). Our own
re-validation reads PPL 10.8797 (10.77/10.91 published for this variant) and
GSM8K 94.5%. And the comparison the fear is about is not available on this
hardware at all: 8-bit weights are ~27 GB against 21.7 GiB of VRAM, so the
model only fits at 4 bits -- the current quality is the achievable quality here,
and it is ~99% of unquantized on the headline metric. int8 *activations* do
cost a little (published +0.9% to +2.2% perplexity), which is why that profile
stays a profile. A 3-bit requantization would be a quality gamble for a decode
gain smaller than the lossless adaptive win already staged above.

### Adaptive verify block: built, mechanism verified, deploy deferred

State of the work (all of it gated behind `VLLM_MTP_ADAPTIVE_K`, so with that
env unset every file behaves as before -- production was re-verified against
the k=4 baseline to the millisecond after each experiment):

* `outputs.py` carries `spec_block_hint`; `gpu_model_runner.py` reads the ask
  after the proposal and knows both strides (`spec_strides`), and
  `_is_uniform_decode` accepts either; `scheduler.py` keeps the configured k as
  the maximum and uses `VLLM_MTP_ADAPTIVE_K` as the base unless the ask stands;
  `llm_base_proposer.py` runs the base probe, a second long probe while a copy
  is running, asks for the long block, proposes the long block's own tokens on
  a long step, chains only the base number of drafts and pads otherwise, and
  holds the block for `VLLM_MTP_ADAPTIVE_STICKY` (default 4) steps after the
  match flag drops; `cudagraph_dispatcher.py` accepts any stride in the set and
  only keys FULL decode graphs for sizes a stride divides; `compilation.py`
  unions the spec shapes with the original capture sizes instead of replacing
  them (replacing them dropped the small shapes and measured slow).

Verified in the live runtime: chat step times match k=4 exactly at 2k/8k/32k/64k
(33.3/35.8/39.3/44.0 ms); the ask reached the scheduler (a k=8 step appears in
the debug trace); a long step reported `count=9`, i.e. all eight lookup tokens
plus the bonus accepted; and the gates correctly refused a coincidental match
(`valid=[4] len=[32] count=[3]` never took the long block). The 60k verbatim
copy measured acceptance 4.21/4.36 against the k=4 baseline's 4.06 *before*
stickiness was added -- stickiness is the piece expected to lift it to ~6-9,
and it is implemented but not yet measured.

To resume: boot `K=8 QMAX=16 CAP=16 VLLM_MTP_ADAPTIVE_K=4` (with
`VLLM_MTP_ADAPTIVE_DEBUG=1` to watch `ADAPTDBG`), run the 60k copy twice,
confirm the sampled path is untouched (`sample_probe`), run GSM8K and PPL, then
bake the six files as one patch, rebuild, prepare and enable through
`serve.env` (`QWEN_EXTRA_ARGS` with a duplicate `--speculative-config` carrying
`num_speculative_tokens: 8`, plus `VLLM_MTP_ADAPTIVE_K=4`).

**Operational gotcha that cost this night: orphaned engines.** `systemctl stop`
on a transient ab unit returns before the engine's child exits, and that child
keeps 16-21 GiB of the card for tens of seconds; the next boot then dies with
"Free memory on device cuda:0 ... less than desired GPU memory utilization",
which reads like a config error and is not. Always: stop, wait ~30 s, verify
`nvidia-smi` reports under 500 MiB (killing whatever holds it in a loop), then
start; and prefer one boot per experiment over rapid restarts.

### Adaptive verify block: measured, and it does not pay (kept out of production)

The block was finished and tuned through five variants on the live runtime.
Every variant is lossless (the sampler verifies everything), chat parity was
achieved (base steps match k=4 to the millisecond), and the mechanism provably
works: the ask reaches the scheduler, long steps appear, and when they engage
they are fully accepted (`count=9`, i.e. all eight lookup tokens plus the bonus
in one step).

It still loses on every configuration measured:

| variant | 60k copy, 1024-token span | chat 64k step | long steps fully accepted |
| --- | --- | --- | --- |
| k=4 baseline (shipped) | acceptance 4.06, **89.9 tok/s** | 45.5-46.6 ms | - |
| long block 9 tokens, full-accept gate | 4.41-4.53, 86.1-87.1 | 43.9-48.6 | 4-10 of 22-29 |
| long block 9, relaxed ask | 3.38, 70.5 | - | 4 of 12 |
| long block 9, productivity hold | 4.37, 86.1 | 48.6 | 5 of 22 |
| long block 7, productivity hold | 4.25, 83.5 | 48.1 | - |

Reading: acceptance rises 9-11% on the verbatim task, but the wider verify at
60k costs more than the extra tokens buy, so end-to-end decode falls ~4%; and
with the machinery enabled chat at 64k loses ~4% as well. The reason the long
block engages so rarely is visible in the debug trace: the benchmark's
repetitive filler produces *long but unreliable* matches (`len=[32]` with
`count=[3]`), and the gates correctly refuse them. The shipped base lookup
(5 tokens per step, greedy only) already captures the reliable part.

What would change the verdict: a cheaper wide verify (the int4 partial kernel's
staging is already vectorized; the int8 score path is closed three ways) or a
workload with sustained verbatim spans whose continuations are actually
correct -- which is what pi's real traffic will show through the acceptance
metric. Until then the default stays k=4 with the base lookup, and none of this
code is in the repository: the staged copy in the live runtime is inert without
`VLLM_MTP_ADAPTIVE_K` and is discarded by the next prepare.
