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

### Closed for this configuration (measured, do not retry)

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
