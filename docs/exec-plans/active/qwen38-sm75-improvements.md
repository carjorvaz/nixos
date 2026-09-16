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
