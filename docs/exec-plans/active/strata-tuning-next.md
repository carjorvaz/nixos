# strata tuning round 2: the prompt path, the verify window, and park

Status: **active, rounds 2-9 - campaign, park fix, measurement/telemetry, flag cleanup, streamed
session RESTORE, patch hygiene, the Turing-unlock round, the pmem-spill enable and the Unsloth
quantization switch done 2026-11-05** (generation 109), plus the v0.2.11 engine bump
(round 13, generation 111). Round 4 adopted nothing; round 5 landed the streamed RESTORE + draft-optional
SAVE/RESTORE + DFlash2 drafter reset and found/fixed a pre-existing SAVE bug; round 6 restored the
four over-read guards + final newline (one-file delta, generation 104) and closed experiment row 9;
round 7 tested and adopted the volatile nlzy/turing-unlock kernel module (`turing-unlock-assessment.md`:
prefill read -5.7 % at 26,134 tokens at the production 280 W cap, -2.0 % at 8.3k, -1.1 % at 4.2k,
decode unchanged, answers bit-identical; no VBIOS flash, power-cycle reversible) and added the pmem
park-spill hybrid **dormant** (flags off by default; write/guard/RAM paths validated, ordinary-turn
restore match is a follow-up before enabling). Generation 106 = engine 2fa52rq... + unlock at boot; round 8 landed the pmem park-spill checkpoint
match (ordinary-turn park -> streamed restore from the stable 225,280-token checkpoint, 5.15 s vs the
152 s reread, identical answers) and enabled the tier in generation 107 (engine gci3izr..., 6 GiB /
4 slots / 4096 MiB reserve + stale-*.park cleanup). Round 8b then landed the CUDA #4677 stop-bound
port and the per-request WSTAT telemetry counters (9 families on /metrics/prometheus, validated and
deployed in generation 108, engine gwhnf6m...): answers unchanged, counters reconcile with the engine
log. Round 9 tested both Unsloth Dynamic V3.1 packs and switched production to UD-IQ2_XS (generation
109): eval320 quality within noise of the old pack (-0.2 pp mean over 3 passes), prefill read
-14.8 % P1 / -11.5 % P8K / -16.3 % L-live, decode +4.1 %, the 39.38 GiB expert pack removes the DAX
register fallbacks and raises the expert cache to 8,898 slots. The UD-IQ3_XXS arm measured +1.4 pp
quality (not significant) with neutral speed and is kept as an optional quality-first alternative.
Open: the DFlash2 drafter refit for the UD pack (its L-live acceptance fell 98 % -> 85 %; scoped in
`dflash2-refit-scope.md` and not recommended - ~+3-8 % decode for 3-6 weeks) and rollback pack
reconstruction if ever needed.  The coder lane is **closed as not wanted** (owner, 2026-11-05): it
is the IQ1_M half-expert (12,288 of 24,576), coding/tool/vision-pruned variant - fast (790.7 tok/s
prefill at 4,344, 1.66x the decode) but 91.3 % of the full model's SWE-bench and weaker outside code
including CJK, i.e. exactly the trade the owner does not want; its pack/shards/shared PLE stay deleted
and it is not to be rebuilt unless asked.  DAX rotation pipelining was measured and rejected, with its
log-only timing seam kept; the 6,784 MiB larger-window arm (2026-11-18) is
also rejected, numbers in `docs/VALIDATION.md`.
Started 2026-11-04, after the generation-100 stack (engine 0.1.56 + DFlash2 + model-card sampling)
was measured. Round 1 is
`docs/exec-plans/active/strata-pack-restore.md`; this plan starts from the regime that record ends
on. Labels: **[M]** measured, **[E]** estimate - expected effects are [E] unless a measurement is cited.

## Goal

Buy back the two costs the 2026-11-04 measurements point at, with evidence: the prompt-read fixed
cost (~5.9 s/request, 41% of engine wall time) and the decode verify window (GPU-wait bound at
27.4-29.5 ms while the CPU side is 4.4-6.8 ms), then land the park/restore source fixes the 8 GB box
needs. Nothing is adopted on one run; a round is accepted only through the decision rules below.

## Non-goals

- No hardware changes this round: the +RDIMM (DRAM 8 -> 40-48 GB over all six channels), a second
  DCPMM for 2-way interleave, and a GPU are **deferred**, not rejected - the box audit ranks DRAM
  first, but this round is software-only (`box-audit.md` §§2-3).
- No other services: the lane stays the boot engine behind the lease proxy; no vLLM/NInfer switch,
  no host OS/sysctl changes, no client/context changes (the 262,144 window stays).
- No engine pin bump was planned when this round started (`ffa80d73` was v0.2.10 and upstream
  `main` HEAD).  That changed when v0.2.11 (`c3b3f503`, engine 0.1.57) shipped on 2026-11-05; the
  bump was taken as round 13 below.  The campaigns run on the isolated port-8099 engine; the Lead
  deploys only what passes its rule, and every deploy is recorded in the progress log below.

## Context: the 2026-11-04 regime shift (generation 100)

Measured on the live stack (engine 0.1.56, DFlash2 on the Q4_0-selector pack, no MTP layer, no
`sampling` block) [M]:

- **Decode is GPU-wait bound now.** Per decode window: `wait for the GPU 27.4-29.5 ms`,
  `pool + plan 4.4-6.8 ms`, staging 0.05, commit 0.006, at a 97.0-99.5% expert-cache hit (typically
  98.7%). The pre-router budget (73 ms pool vs 18 ms GPU, `tiberius-latency-tricks.md`) is inverted;
  the CPU-pool family is closed.
- **The live workload is not the campaign workload.** `/metrics` totals: 817-829 requests, 559 k
  generated tokens over 6,198 s = **90.3 tok/s mean decode**, 87.2% draft acceptance (recent
  requests 92-95% / 104-110 tok/s); campaign cells measure 57-63 tok/s at 68-78% on summary text.
  The gap is the workload, not the engine: the benchmark's short high-entropy continuation is a
  different acceptance regime.
- **Prompt reads are 41% of engine wall time and were never campaigned.** Fitting all 828 prompt
  lines of the gen-100 log gives `read_ms = 5,910 + 0.799 x fresh_tokens`: marginal 1,251 tok/s, a
  **5.9 s fixed cost per request** (8.7 s when `reused == 0`, 4.6 s on reuse), 12,147 s of the
  29.4 ks uptime. A 100-fresh-token request still costs 3.4-4.0 s - the dominant TTFT term.
- **Prefill is a per-chunk whole-pack DAX stream.** The 46.84 GiB / 48-layer pack sits behind a
  6.00 GiB sliding window: **9 registrations per pack pass** (`0..5` 5.52 GiB ... `46..47`
  2.31 GiB), experts read from DAX (the OS read 0.0 MB from storage), and one rotation is a
  copy-stream drain plus unregister/register of ~5.5 GiB. The 1,251 tok/s marginal is the DAX
  stream; the 5.9 s intercept sits above it.
- **RAM is still the software ceiling.** MemAvailable 0.9-1.2 GiB, 893 "skip parking" admissions,
  493 cache evictions, 1.37 GiB of engine in zram; a 250k disk RESTORE needs 3,727 MiB plus the
  floor against ~2,050 MiB available and is refused - the binding constraint on multi-client reuse.
- **Nothing upstream to bump.** `git ls-remote` on 2026-11-04: `main` = `ffa80d73...` and `v0.2.10`
  peel to the same commit; #4677 (park stop-bound) is HIP-only, so this CUDA build has no counterpart.

Evidence: `docs/exec-plans/active/strata-pack-restore.md` §§ "v0.2.10"/"Post-bump experiments" and
`docs/VALIDATION.md` §"Tiberius Strata runtime"; the 2026-11-04 reports (local, not committed) at
`/tmp/strata-tune/` (experiments §§0/2/4/6, engine-knobs §§0/1.2/2/3/4, box-audit §§1.3/2). Harness:
`/data/ab25.py` + `/data/ab25-serve.sh` (fresh engine, port 8099, GPU lock, trap restores
production); cells P1 4,252 tok +256 gen, P2 3,477 +256, P27 26,134 +8.

## Ranked open experiment matrix

Ordering = expected value / cost; all arms are flag-only (patch items are a separate roadmap).
Commons: fresh engine per run, >=3 counterbalanced runs for any claim, `temperature: 0` per request,
answer sha, means with [min-max], production restored by trap. *Bitwise* = the bits should not move
(verify sha anyway); *answer-drift* = the arm also needs eval80 + needle/repetition probes.

| # | experiment | arms | cells | runs/arm | expected effect | risk class | decision rule | status |
|---|---|---|---|---|---|---|---|---|
| 1 | prompt-path fixed cost (C1) | base; `--prefill 16384`; `8192`; `8192 --no-prefill-borrow` (`user_args`); `STRATA_PREFILL_TIMING=1` diagnostic | fresh-prompt sweep 18/128/256/512/1024/2048/4252/8192/16384/26134 (+1 P1 repeat); reserve arms P1/P2/P27 | 1 sweep engine + 2/reserve arm | remove >=3 s of the 5.9 s intercept at >=97% hit; 41% of wall time | mostly bitwise (buffer reservations), but a borrow change shifts expert slots and can drift answers (ab11) - sha gate | adopt if a flag removes >=3 s/request at >=97% hit and <=1% decode cost; if timing puts >=2 s in an engine-internal phase, open the patch item with those phase numbers | measured 2026-11-04: no flag removed the fixed cost - `16384`/`8192`/`8192 --no-prefill-borrow` cost +10.3/+56.3/+52.0% P27 read and no-borrow drops to 4,959 slots; closed for flags, prompt-path patch item (DAX pack-stream/copy wait) |
| 2 | routed-stream | `STRATA_PREFILL_ROUTED_STREAM=1`; then `=1` + `_DEPTH=32`; confirm the engine's "streamed prompt chunk drops the experts no token routes to" line | same sweep + P27 | 3 counterbalanced | -8..-25% read on the 1.1-4.3k chunks that dominate live traffic; -3..-5% at 28,160 (upstream 2K -20 / 4K -8 / 32K -5%) | bitwise per source (same slots, same order); sha + hit unchanged | adopt if read improves >=3% on >=2 chunk sizes with identical sha; else close | measured 2026-11-04: active, but +32.6..+87.9% read on every cell >=1024 tok (P27 +37.8%); rejected |
| 3 | DFlash2 window axis (lookup) | `--lookup-max-t 8`, then `12` (`user_args`), `--draft-conf 0.8`; default is **0** under DFlash2 (`lookup_default.hpp:23-30`), so no lookup windows run today; explicit N raises `--spec` to min(N,16), spec_cap 16 (9-16-row windows = two groups of 8) | P1/P2/L-live (structured/code prompt >=600 tok, `ignore_eos`, max 768; base acceptance >=85%) | 3+3; finalist 5-6 | +3-10% decode on rewrite/edit-heavy text, ~1% on prose; 26k smaller | answer-drift (wider windows change sampling acceptance; greedy sequence-parity gate) | adopt if L-live decode +>=4% in >=2/3 runs, reads within +/-1.5%, eval80 not >8 tasks worse | measured 2026-11-04: `--lookup-max-t 8` is a no-op (verify window stays 8), `12` is -1.4% L-live decode; default 0 kept. 2026-11-23 (DFlash2, 0.1.63): 9/12 rows error with `native ERR dflash2: draft rows out of range` - the arm cannot run; copy text already runs 97.5 % acceptance at the 8-row cap. **Closed for this lane** (round 17) |
| 4 | spec / draft-cap / conf | `--spec 4`, `--spec 8`, `--draft-cap 8`, then `--draft-conf 0.7` and `0.9` at the best width. Serve injects `--spec 6 --draft-conf 0.8` and strips the config `--spec`, so overrides go in `user_args` | P1/P2/L-live | 3; finalists 5-6 | 0-4% decode (window width on a GPU-bound loop); conf 0.7/0.9 likely +/-2% | answer-drift (sampling; greedy sha gate) | spec/cap: same rule as row 3; keep conf 0.8 unless 0.7/0.9 show >=4% decode with sha parity | measured 2026-11-04: spec8 -2.9% L-live decode (more tok/window but slower windows), answers drift on P2/P27; `--spec 6 --draft-conf 0.8` kept; conf 0.5/0.65 closed 2026-11-04 - underpowered (base spread 6.4%), answers changed, 0.8 stays (`/data/ab38-*`) |
| 5 | k8v4 long-context | `--kv int8` (deployed) vs `--kv k8v4` | P1/P2/P27 + 26k/38k decode | 3+3 | +0-8% decode at 22-38k; int8 1,056 vs k8v4 816 B/cell (-23% KV bytes) and more slots; prior 0.1.49.2 screen was +6% on one short cell, 0.1.52/router within noise | answer-drift (V becomes rotated Q4_0; KL/top-1 gate + eval80 + needle 3/3) | adopt only if decode +>=2% on >=2 cells or hit +>=1 pt, eval80 not >8 worse; else keep int8 | measured 2026-11-04: L-live -10.7% decode, P27 read +10.5%, long-context +2.6% (below the 3% gate); int8 kept |
| 6 | tail-skip | `STRATA_ROUTE_TAIL_SKIP=8`, then `9` (deployed 7; 96.6% of missed entries are already skipped at rank 7) | P1/P2/P27 | 2-3 bracketed, promote to 3+ if >=2% | 0-3% decode | answer-drift (KL rises from the adopted 0.0058 baseline; acceptance can fall at high cache %) | adopt only if decode >=2% on >=2 cells with eval80 not >8 worse and needle 3/3 | measured 2026-11-04: skip8 -5.3/-4.6/-10.7/-7.3% and skip9 -4.9/-10.4/-13.5/-4.7% on P1/P2/L-live/P27d; 0/3 decision cells >=+2%; **closed, 7 stays** |
| 7 | route-prior 1.35 | 1.2 (deployed) vs 1.35 | P1/P2/P27 | 2 campaign + full quality battery (eval80 x2, 9-turn continuation x2, 27.8k needle 3/3) | between 1.2 (clean) and 1.5 (26k 77.8 vs 61.4 tok/s but degenerated on the 9-turn probe); 1.35 unmeasured | answer-drift by construction; degeneration is the failure mode | adopt only if decode +>=5% on >=2 cells AND needle 3/3, repetition clean 2/2, eval80 within 1 sigma; else close the family | measured 2026-11-04: L-live -6.29%, P2 -7.54%, P27d +2.23% (0/3 cells >=+5%); the acceptance drop on the alternate continuation (98.8 -> 84.1%) explains it; **closed, 1.2 stays** |
| 8 | conversation-cache sizing | 2048/4/min-free 384/park-gain 512 (deployed); 1024/3/384/512; 2048/4/512/512 | 2.4k isolation probe interleaved with a 19.4k foreign request (5 probes/arm) + one 20-request mixed run | 1 engine start, 5 probes | refused-park lines -50% (893 now), reuse share within 2 pts; RAM pressure is the binding term, not the flags | no answer change (cache policy only); OOM risk below the 384 MiB floor - never test lower | reduce the budget only if refusals drop >=50% with reused share within 2 pts | measured 2026-11-04 with prompt-cache 3 and cache1024: deployed 0 pressure refusals in the isolated window and 5/5 turn-2 prefixes at 98.5% reuse; the narrowed arms never beat that (promptcache3 had the only refusal); **closed, deployed settings stay** - production pressure is a RAM-capacity effect, not a cache-flag one |
| 9 | reserve geometry | auto (deployed), `--vram-reserve-mib 0`, `512` (768 was closed at ~6.2k slots: -2 hit points) | P1/P2/P27 | 2-3 | <=1%; confirm the 7,859-slot / 777 MiB-free regime has not re-opened the #2065 paging state | bitwise paths, but a slot/residency change can drift answers (ab11) - sha gate; VRAM OOM at reserve 0 | keep deployed unless >=1% on >=2 cells with vram_free >=400 MiB | closed 2026-11-05 without a window: the prior 768 MiB arm cost 2 hit points by taking ~400 slots, the deployed start reports 777 MiB free with no `KV window`/paging line in every campaign/deployment since, and the expected effect (<=1%) is below this harness's measurement floor; the auto default is kept. Reopen only if a start ever prints the paging/KV-window warning again |

Rows 1-2 were campaign block A, 3-5 block B on 2026-11-04 (rows 6-9 deferred); the measured
verdicts are in "Round 2 campaign results" below. No adopted arm and no partially closed sub-arm
reopens without the stated quality gate.

## Round 2 campaign results (2026-11-04)

Two maintenance windows ran the matrix on the isolated port-8099 engine: the deployed 0.1.56
binary, a fresh engine per arm, the GPU lock, and a trap that restarted `tiberius-strata` and
waited for `/health` after each window. Cells: P1 = 4,252 tok + 256 gen, P2 = 3,477 + 256, P27 =
26,134 + 8, P27d = the P27 prompt repeated with 64 gen from its parked prefix (long-context
decode), L-live = a fixed structured-JSON fixture prompt under `ignore_eos` (768 tok; base
acceptance 98.8%, 110.05 tok/s - the live-regime cell). Window downtime: **16.4 min** (block A)
and **24.4 min** (block B); production was healthy and warm after each. Raw artifacts:
`/data/campaign-2026-11-04/`; condensed report `/tmp/strata-tune/campaign-results.md` (both local,
not committed).

### Block A - prompt path

| arm | P1 / P2 / P27 read, delta vs base (n=1) | note |
|---|---|---|
| base | 8,607 / 8,415 / 21,022 ms | 7,859 expert slots, 777 MiB free |
| `--prefill 16384` | +2.9% / +3.3% / **+10.3%** | no intercept gain |
| `--prefill 8192` | +1.5% / +4.9% / **+56.3%** | serve layer also auto-picked `--draft-conf 0.7` |
| `--prefill 8192 --no-prefill-borrow` | -3.1% / -2.2% / **+52.0%** | expert cache collapses to 4,959 slots (-37%), hit floor 94.8% |
| `STRATA_PREFILL_ROUTED_STREAM=1` | +75% / +82% / +38% | active per its log line; sweep +39..+88% on >=1 k prompts |
| `...=1` + `_DEPTH=32` | +66% / +73% / +33% | same picture |
| `STRATA_PREFILL_TIMING=1` (diag) | +0.2% | log-only |

The prompt path's fixed cost is real and reproducible: the 4,252-token prompt re-ran at +0.7%
a second time with `reused=0`, and a fresh-prompt sweep (42..26,142 tok) fits `read_ms = 4,434 +
0.637 x tokens` over all points, `5,110 + 0.598 x tokens` excluding the sub-100-token regime
(the live-log fit, 5.9 s + 0.8 ms/tok, sits inside this family), `6,445 + 0.525` for >=1,024-token
prompts. The `STRATA_PREFILL_TIMING` breakdown puts the short/mid-prompt term in the DAX
pack stream: at 4,245 tok, `wait copy` is 2,626 ms of a 7,111 ms GPU timeline (36.9%) and host
grouping 783 ms (11.0%); at 26,127 tok `wait copy` is only 594 ms (3.7%) and the timeline is
compute-bound (gemm gate/up 2,385 ms, qsa attn 1,616 ms, gdn 1,444 ms). So the remaining
prompt-path win is the DAX rotation/copy overlap (roadmap item 2), not a flag.

### Block B - decode window and quality

| arm | L-live decode (n=2 + range) | long-context P27d decode | eval80 (t=0) | answer sha | verdict |
|---|---|---|---|---|---|
| base | 110.05 [109.50-110.60] | 65.50 [65.30-65.70] | 60/80 | canonical | benchmark arm |
| spec8 (`--spec 8`) | 106.85 [106.70-107.00] (-2.9%) | - | 63/80 | drift P2/P27 | keep 6 |
| lookup8 (`--lookup-max-t 8`) | 109.90 (-0.1%) | - | 60/80 | identical | effective no-op (verify window stays 8) |
| lookup12 | 108.50 (-1.4%) | - | 60/80 | identical | keep 0 |
| kv8v4 | 98.30 [97.90-98.70] (-10.7%) | 67.20 (+2.6%, below the 3% gate) | 63/80 | drift every cell | keep int8; P27 read +10.5% |

Window mechanics: differencing the engine's cumulative stage-0 counters gives base 5.69
tok/verify-window at 27.6 ms GPU wait, spec8 7.38 tok/window at 33.7 ms, kv8v4 4.77 tok/window
at 84.7% acceptance - wider windows bought tokens, not throughput. Sampling: card 58.67
[58-59] vs card0 58.00 [56-60] over 3 passes each - keep the model card. The answer-sha column is
a drift detector, not a pass/fail gate: the same-config base and timing arms also differ on P1/P2
because the residency-biased route prior makes fresh-engine state part of the answer.

### Verdicts

- **Adopted: nothing.** The module's run config stays byte-identical (all arms were kept or
  rejected against their pre-registered rules).
- **Kept:** `--prefill 28160` with the prompt borrow; DFlash2 `--spec 6 --draft-conf 0.8`;
  `--kv int8`; model-card sampling; routed stream off.
- **Rejected:** routed stream (both depths); `--prefill 16384`/`8192`/`8192 --no-prefill-borrow`;
  spec8; lookup8/lookup12; kv8v4; sampling card0.
- **Needs-patch:** the prompt-path fixed cost is DAX pack-stream/copy wait, not host setup, so
  roadmap item 2 (two resident registration windows, copy overlap) is the next performance item.
  The transactional-park fix (roadmap item 1) is this round's robustness change; its isolated
  probe and deploy are recorded in the progress log below.
- Operator notes: the serve layer strips `--draft-cap` from `user_args` (the cap follows
  `--spec`); `--prefill 8192` arms auto-selected `--draft-conf 0.7`; the 8-gen P27 decode was
  never used for a decision; eval80 is a guardrail only.

## Round 3 results (2026-11-04)

Software-only round; no hardware change. Generation 102 was deployed at 18:47 (service healthy,
smoke completion, the unchanged 7,859-slot / elastic-K/V / DFlash2 / 5.52 GiB DAX start, and the
new `tiberius-strata-telemetry.timer` active).

### DAX rotation pipelining - measured, rejected, timing seam kept

One 11.0-min trap window (production restored, warm, `postflight_fail=0`): base = deployed
`3qla1qfa...`, patched = `68960zpz...` (patch sha `fa6d6a17...`), 3 counterbalanced runs/arm plus
2 same-binary `STRATA_DAX_PIPE=0` control runs; cells 4,260 / 8,276 / 26,142-token reads +8 gen,
greedy, `reused=0` everywhere.

| cell | base read_ms mean[min-max] | patched two-window | patched PIPE=0 control |
|---|---|---|---|
| 4,260 | 8,591 [8,563-8,622] | 8,734 [8,700-8,772] **+1.66%** | 8,739 (+1.72%) |
| 8,276 | 10,072 [9,872-10,289] | 10,488 [10,328-10,778] **+4.13%** | 10,155 (+0.82%) |
| 26,142 | 20,830 [20,748-20,907] | 19,698 [19,394-19,881] **-5.43%** | 21,187 (+1.71%) |

Rotations/pass went 8-9 -> 18-19, zero registration refusals, P1/P8K answer shas identical in
every arm, P27 sha deterministic per arm but different in the pipelined arm (`719ac447` vs
`a16eafe9`). The new `STRATA_DAX_TIMING` lines attribute it: fence/stream-drain wait 0.0 ms, but
unregister 1.68-2.74 s and register 1.44-2.30 s per cell (~215-245 ms/rotation); halving the run
doubles the driver work, and the overlap does not pay it back on short/mid prompts. **Rejected;
only the log-only `STRATA_DAX_TIMING` instrumentation is retained** (patch sha `cd67094e...`,
one marker grep; default-off, zero run-config change) as the seam for a future, different
mechanism. Evidence: `/data/dax-ab/` (results, per-run logs with every timing line, DECISION.md).



### eval320 / McNemar / PPL harness - landed (C9 met)

`/data/eval320/` (box-local, public-safe counters only): 320 held-out exact-answer items, sha256
`567d10be...`; arithmetic 80 / conversion 40 / logic 60 / python_output 60 / structured_data 60 /
code_output 20, 106 easy + 86 medium + 128 hard, ground truth programmatically verified 320/320;
`evalmcnemar.py` (paired McNemar, exact p, risk difference, paired-bootstrap CI, test-retest
agreement + kappa); `ppl.py` (fixed 3,100-token corpus, 128 greedy tokens, OpenAI-style
`logprobs` via the chat endpoint - `/v1/completions` is 404 on this build). Baseline on the
generation-101 engine: **pass1 186/320 (58.1%), pass2 191/320 (59.7%)**; test-retest 19/320
flips = **5.9%**, agreement 94.1%, kappa 0.8774, McNemar p = 0.359 (no same-stack difference).
That is the variance floor: a ~2.8 pp net edge is now detectable (z~2.8), so eval320 can rank
answer-changing arms where eval80 cannot. PPL repeats: mean token logprob -0.2209/-0.1623 (ppl
1.247/1.176) on pass1 and -0.1548/-0.1606 (1.167/1.174) on pass2; the gate is usable but greedy
continuations are not bit-repeatable past ~51/128 tokens, so compare paired on the common prefix
and treat <0.05 nats as noise. Evidence: `/data/eval320/RESULTS.md`,
`/data/eval320/logprobs-support.md`.

### Telemetry - deployed

`profiles/nixos/strata-telemetry.nix` (new module, wired into `hosts/tiberius.nix`): a 15 s
oneshot timer writes one compact JSON line per scrape to `/persist/strata/metrics/YYYY-MM-DD.jsonl`
(daily files, 14-day prune) with live state/rates, expert slots, VRAM free, park/restore/eviction
counters, GPU temp/power and totals; drift warnings via `logger -t strata-telemetry` for decode
below 70% of a 20-answer-sample median, two consecutive scrape failures, GPU >= 82 C and
evictions rising by >5 in 5 min, with hysteresis so a transient does not spam. Verified live:
timer active at 15 s, valid lines, journal clean. First decode warning needs ~5 min of answering
traffic to fill the median ring.

### Validation and park-fix production evidence

- The repo's pre-existing statix repeated-key warnings were merged away (`profiles/nixos/mail.nix`,
  `hosts/hadrianus.nix`, `hosts/tiberius.nix` - one `systemd`/`services` wrapper each, semantics
  checked by comparing the evaluated unit/service/wait-online sets; the systemd wrapper change was
  validated against the original evaluated values). `scripts/validate` now completes successfully,
  including deadnix/nixfmt/statix and every host evaluation.
- Park fix in production (generation 101, first ~15 min of traffic): 11 parks, 5 restores, 4
  legitimate admitted-after-evict lines, and **7 "nothing evicted, N still parked" refusals** -
  seven refused parks that would each have destroyed up to two parked conversations before the fix.
  The new telemetry will make this rate visible.
- Deployed generation 102: system
  `/nix/store/ppprl8ix6cd49k7lp2nzijzgks8sb61z-nixos-system-tiberius-...`, engine
  `/nix/store/ixssrl2q9qihzvl0xwhrp3iia9vx5fhf-strata-engine-0.1.56` (transactional park +
  `STRATA_DAX_TIMING`), 7,859 slots, elastic K/V, DFlash2, 5.52 GiB DAX; service healthy and warm.

### Still open

Streamed session RESTORE (roadmap item 3) was not attempted this round and is the next patch
candidate; pmem park spill (item 4), the CUDA #4677 port (item 5) and the per-window counters stay
open. Flag experiments rows 6-9 were not run this round.

## Round 4 results (2026-11-04)

Two trap windows (13.2 min and 22.3 min downtime, production restored warm after each; telemetry
timer stayed up). Purpose: close the remaining flag rows with the new eval320-based quality
discipline, and test whether a smaller host-RAM footprint buys back park admissions. **Adopted
nothing; the run config is unchanged and generation 102 stays deployed.**

### Route-prior and tail-skip (isolated engine, 11 runs)

3 arms x 2 counterbalanced runs first (base included), cells P1 4,252 / P2 3,477 / L-live /
P27d (26,134-token parked-prefix reuse, 64 gen); the base arm was stable (L-live spread 0.64%,
P1/P2 <=0.2%) and reproduced the 2026-11-04 baseline. Decode means, delta vs base:

| arm | P1 | P2 | L-live | P27d |
|---|---|---|---|---|
| base | 60.25 tok/s | 62.30 | 109.75 | 64.95 |
| prior135 | +2.07% | **-7.54%** | **-6.29%** | +2.23% |
| skip8 | -5.31% | -4.57% | **-10.66%** | -7.31% |
| skip9 | -4.90% | -10.43% | -13.53% | -4.70% |

Reads were flat or better in every arm, so the losses are decode, not prefill. All three arms
rerouted L-live onto the same alternate continuation (`51d49971`, the text the k8v4 arm produced
in the 2026-11-04 campaign) whose draft acceptance collapses 98.8% -> 84.1-84.8% - more verify
windows, fewer tokens per window - which is why a "more aggressive skip/prior" arm loses on the
live-shaped cell even where P27d nudges up. Rules were pre-registered and failed at the screen
(prior135 0/3 cells >=+5%, skip8/9 0/3 cells >=+2%), so no eval320/repetition/needle window was
spent: **route-prior family closed at 1.2, tail-skip closed at 7.**

### Conversation-cache / prompt-cache probe

One fresh gen-102 engine per arm, 5x (2.4k conversation interleaved with a 19.4k foreign request)
+ one 20-request mixed run, refusals parsed from the gen-101+ wordings:

| arm | pressure refusals | admission evictions | turn-2 kept | reused tokens | reuse share | turn-2 read mean |
|---|---|---|---|---|---|---|
| deployed (2048/4/384/512, prompt-cache 6) | 0 | 13 | 5/5 | 2,606.6 | 98.54% | 1,100 ms (one 3,144 ms evicting restore; others 541-618) |
| prompt-cache 3 | 1 ("nothing evicted") | 2 | 5/5 | 2,615.6 | 99.08% | 558 ms |
| cache1024 (1024/3) | 0 | 0 | 5/5 | 2,622.0 | 99.08% | 569 ms |

The pre-registered rule needed a >=50% drop in pressure refusals with reuse within 2 points; the
deployed arm produced *zero* refusals in the isolated window (with production stopped the box has
far more free RAM than its steady state), so the trigger cannot fire there, and the only refusal
came from the narrowed arm. The deployed cache already keeps 5/5 prefixes at 98.5% reuse. The
production pressure visible in telemetry (41 requests / 37 parks / 24 evictions in 23 min) is a
RAM-capacity effect, not a cache-flag one: **cache settings stay** (a RAM purchase remains the
fix; see box audit).

### Streamed session RESTORE - design complete (next patch round)

The design study (against pristine `ffa80d73`) finds the streaming path feasible with **no file
format change**: two passes over one fd - pass 1 validates the v1 header/trailer/payload hash with
metadata-only allocations, pass 2 re-parses and streams each K/V section straight into the session
pools through one 16 MiB pinned block. The ~3.5 GB K/V section is last in the file, and the parts
that genuinely stay in host RAM (live + deepest checkpoint ~118 MB each, ids ~1 MB) put the 250k
peak at **~260 MB** instead of today's 3,727 MiB; the RAM gate moves after pass 1 and uses the
exact metadata-derived peak (`session_stream_peak_bytes`), preserving the existing
refuse-before-any-device-write and fatal-after-first-write contracts. Estimated patch: ~700-750
lines over 5 engine files + ~150 test lines; validation window 15-20 min (250k save -> restart ->
restore, VmHWM delta <=400 MB, restore <=10 s, continuation sha, 50k regression, corrupt-file
refusal, normal-park regression). mmap-on-DAX was checked and rejected (same 236 MB state floor,
needs a non-owning ConversationBuffer, SIGBUS risk, DAX-only). **Adjacent bug found:** RESTORE
never invalidates the DFlash2 drafter (`df2.reset()` missing after a successful restore), so a
rewind leaves the drafter's slot shadow describing overwritten K/V - answers stay verified but
draft acceptance collapses; that is a separable ~2-line fix and can land before the full patch.
Design: `/tmp/strata-tune/stream-restore-design.md`.

### Round-4 verdict

Nothing adopted; config unchanged (1.2 / 7 / int8 / DFlash2 / 2048-4-384-512 / prompt-cache 6).
Rows 6, 7 and 8 of the matrix are closed by measurement; only row 9 (reserve geometry) remains as
a flag row. Next round is the streamed RESTORE patch (with the DFlash2 reset fix first), then
pmem park spill stays deferred.

## Round 5 results (2026-11-04)

Goal: make disk sessions usable on this box (streamed RESTORE, so a 250k session no longer needs
its 3.7 GiB image in host RAM) and fix the adjacent DFlash2 drafter shadow on restore. Implemented
as a fourth local change in `tiberius.patch` (11 file sections; ~750 lines + host-only tests), with
`df2.reset()` after a successful restore. Two independent code reviews before the live runs caught
a critical pass-1 validation bug and, in the delta pass, a park-snapshot validator regression - both
fixed; the final patch sha `829b20ec` was reviewer-cleared before the successful window.

Two validation windows exposed a pre-existing bug: **SAVE had never worked on the deployed
DFlash2-alone lane.** `conversation_snapshot_sources` passed `mtp.kv_state()` unconditionally; with
no `--mtp` bound that is an empty QsaState, so `valid_extent()` refused every save with
"invalid K/V extent" (the empty sessions directory was the symptom; the 2026-11-01 SAVE numbers in
the round-1 plan were measured on the MTP lane). SAVE/RESTORE now make the draft layer optional in
both directions (MTP files unchanged; DFlash2 files layers-only; mismatched files refused), which
is the half of this round that makes the feature usable at all.

Validated on the isolated port-8099 harness (patched build
`/nix/store/gv3vlx7ah...-strata-engine-0.1.56` vs deployed gen-102):

| check | result |
|---|---|
| DFlash2 SAVE, 240k | SAVED 239,200 tok, kept 1 of 6 checkpoints, 3,636,601,128 B, 4,758 ms |
| streamed RESTORE, fresh engine | 239,200 tok / 3,636,601,128 B in 5,240 ms (<=10 s); VmHWM +259 MiB (<=400); no refusal |
| continuation after restore | greedy sha `c5353fcf...` == pre-save (240k); 50k `3cb3fa1d...` == pre-save |
| 50k round trip | restore 1,409 ms, RESTORE->GEN->SAVE->RESTORE sha equal |
| old-writer compat | gen-102 MTP-lane 50k file (1,001,743,772 B) restored streamed in 1,519 ms, sha equal |
| cross-lane file | HTTP 400 invalid "saved with another model (fingerprint differs)", same pid, next GEN ok |
| corrupt / truncated / header | HTTP 400 invalid, same pid, no restart, next GEN ok |
| park regression | restored/borrowed reused=1,738 > 0, zero "discard invalid snapshot"/"cannot borrow" lines |
| copy-failure seam | `=1` HTTP 500 io (engine alive, next GEN ok); `=2` FATAL, engine exits, next request restarts it, no partial answer |

The two probe OOMs seen en route were probe-host pressure (a restored multi-GB conversation parked
plus three 0.95 GB corrupt copies in RAM on the 8 GB box), not engine contract violations - fixed in
the probe (streamed copies, 50k-only format engine) and no partial answer was served. **Deployed as
generation 103** (system `/nix/store/56fx2bkqqbpq5bc7z973z288n8d9f517-...`, engine
`/nix/store/gv3vlx7ah...`); start line unchanged (7,859 slots, elastic K/V, DFlash2, 5.52 GiB DAX),
`/health` ok on both doors and a smoke completion answered. Follow-ups for the next regeneration of
the patch: restore the four "payload ends early" over-read guards and the missing final newline
from `conversation_file.cpp` (hardening/style only; over-reads still refuse via `left != 0`/IO).

## Round 6 results (2026-11-05)

Purpose: close the last two loose ends before the next large patch - the accepted patch-hygiene
follow-ups and experiment row 9 - record the external Turing-unlock assessment, and design the
remaining large lever (pmem park spill). No hardware change; production stays on the same
configuration.

### Patch hygiene (deployed as generation 104)

Regenerated `tiberius.patch` to restore the four "payload ends early" over-read guards
(`In::raw`, `In::skip`, and both streamed K/V spans) that were present at the round-5 review
snapshot and accidentally dropped in the final cut, plus `conversation_file.cpp`'s missing final
newline. Proven to be the *only* delta: full patch order on pristine `ffa80d73` vs the deployed
generation-103 tree differs in exactly one file, by 4 guard lines + the newline. Patch sha
`5c05df8b...`; host-only tests 214/214 + 4,842 checks; built
`/nix/store/sz2dwc0k...-strata-engine-0.1.56`. A 2m21s isolated smoke window confirmed no
behaviour change: 50k SAVE -> restart -> streamed RESTORE in 1,459.7 ms with the same greedy sha;
corrupt/truncated/header all SERR invalid with the same pid and a working next request; the
two-conversation park spot check restored 1,738 tokens with zero invalid-snapshot lines.
**Deployed as generation 104** (system `/nix/store/j73nq77...`); service healthy, smoke answered,
telemetry timer active, start line unchanged.

### Experiment row 9 closed without a window

`--vram-reserve-mib` geometry is closed by measurement-adjacent evidence rather than another
production stop: the one prior arm (768 MiB) cost 2 hit points by taking ~400 slots, every start
since reports 777 MiB free with no `KV window`/paging line, and the expected effect (<=1%) is below
this harness's measurement floor. The auto default is kept; reopen only if a start ever prints the
paging/KV-window warning. The matrix now has no open flag rows.

### Turing-unlock assessment (external lever): do not attempt on tiberius

Recorded in `docs/exec-plans/active/turing-unlock-assessment.md`. Upstream
(github.com/haohervchb/Turing-unlock) is a volatile pre-OS EFI payload that raises FP16-in/
FP32-accum MMA and integer IMLA4 from half to full rate on one specific ASUS TU102 card (1.996x MMA,
1.769x cuBLAS GEMM in its own measurements; mining showed no gain; IMLA4 has no dedicated A/B). It
cannot be run from the public repo: the build needs private firmware inputs (the test card's FWSEC,
a Dell A14 root-bridge PE, pinned CMP-unlock blobs), and the runtime guards pin PCI BDF/device/
subsystem/BAR0/firmware bytes to the original Alienware machine. tiberius differs at every one of
those layers (`10de:1e04` / `1043:8687` / VBIOS 90.02.17.40.0E / 22 GB mod / TYAN board / systemd-boot
/ driver 595). The upside for this engine is also bounded: dense FP16 tensor-core GEMMs are a few
percent of prompt time and decode is verify-window bound; a generous bound is low single-digit
percent of prompt read, with nothing on the measured fixed cost. Risk is a pre-OS DMA mutation of
the only production GPU whose documented failure mode holds the box in UEFI and needs a full power
cycle - on a 28-min-POST host with no spare card. Revisit only with a spare identical card + test
rig, private firmware inputs, an upstream persistence/recovery wrapper, and a measured
FP16/FP32-accum or IMLA4 bottleneck.

### pmem park spill designed (next large patch)

The design study (see roadmap item 4 and `/tmp/strata-tune/pmem-park-design.md`) recommends the
adaptive hybrid: RAM parks unchanged, and a refused park is written as a v1 session file on
`/optane` (the existing SAVE writer + the generation-103 streamed RESTORE) instead of being dropped,
with a metadata-only parked-cache entry and a new tier gate. It converts the production failure
mode - size-proportional RAM admission at ~4,276 MiB for 250k - into a constant capture plus the
floor, so the logged refusals become file parks and subsequent turns reuse (164 s re-read at 250k
replaced by a ~5 s restore). ~800-950 engine lines + tests, 15-20 min GPU window; the main risks are
Optane thermal headroom and write volume. This is the next round's candidate.

## Round 7 results (2026-11-05)

Two goals: test whether the Turing tensor-core unlock can really help prefill, and land the remaining
large software lever (pmem park spill). No hardware change; the 280 W power cap is unchanged.

### Turing-unlock: tested on tiberius and adopted

The <https://github.com/haohervchb/Turing-unlock> EFI payload remains inapplicable (private firmware
build inputs, Alienware-board guards; see `turing-unlock-assessment.md`). The second project,
<https://github.com/nlzy/turing-unlock>, is a GPL kernel module that runs in the initramfs before
nvidia binds, executes pinned NVIDIA 610.43.03 Booter/ACR firmware and writes the two TU102 speed
selectors (SS0=0x88888888, SS1=0x8) - volatile, no VBIOS flash. Its device table covers our
`10de:1e04`, so it was tested in a one-shot systemd-boot generation (module + six firmware files in
the initrd, `turing_unlock.targets=0000:17:00.0`, normal generation kept as the default). Boot log:
`unlock result: ss0=0x88888888 ss1=0x8 readout=0x0`, `TU102 FEAT UNLOCKED`; nvidia 595.71.05 bound
normally, no Xid, idle 41 C. A controlled locked-vs-unlocked A/B (same engine/config/boot, 200 W for
both states, 2 fresh-engine runs per cell) measured:

| cell | locked | unlocked | delta |
|---|---|---|---|
| 4,252-token read | 8,604 ms / 494 tok/s | ~8,518 ms / ~499 tok/s | -1.0 % |
| 8,268-token read | 10,271 ms / 805 tok/s | 10,008 ms / 826 tok/s | -2.6 % |
| 26,134-token read | 22,488 ms / 1,162 tok/s | 21,103 ms / 1,238 tok/s | -6.2 % |
| L-live decode (768 gen) | 90.85 tok/s | 91.05 tok/s | +0.2 % (none) |

At the production 280 W cap the unlocked numbers were 8,495 ms (-1.1 %), 9,870 ms (-2.0 %),
19,610 ms / 1,332.7 tok/s (-5.7 %) and 109.4 tok/s decode (flat), so the gain is attributable to the
unlock, not the cap. Answer shas were identical in every cell and both states. Phase attribution put
the gain in the dense/projection FP16 MMA phases (gdn -37 %, qsa proj -39 %, hc read -34..-65 %),
with the quantized MoE expert GEMMs flat (+1.8 %/+1.4 %) - exactly the FMLA32 path the unlock
targets; decode stays power/GPU-wait bound. Safety: no persistent writes (BAR0 MMIO + firmware-run
selectors only), power-cycle reversible, boot continued locked if the module refuses, benchmark temp
max 60 C and no Xid; the card's 280 W cap binds in both states. **Adopted** via
`pkgs/turing-unlock` + `profiles/nixos/turing-unlock.nix` (`hardware.turingUnlock.enable = true` on
tiberius): the module is built against the plain nixpkgs kernel of the booted version (version
asserted; fsdax kernel patch does not change the module ABI, CONFIG_MODVERSIONS off) and the six
firmware files are generated at build time from two pinned NVIDIA/CachyOS artifacts - proprietary
blobs are never committed to the public repo, and the assessment records the URL-rot/maintenance
caveat. Generation 106 boots with it; residual risks: single card/boot/driver-generation evidence,
and upstream's warning that full-rate tensor cores draw high power (watch telemetry, keep 280 W).

### pmem park-spill: implemented and deployed dormant

The hybrid from `/tmp/strata-tune/pmem-park-design.md` was implemented as patch `a833153c` (~775
lines: a metadata-only file tier + the forced-fallback park writer reusing the v1 SAVE writer with
streamed K/V + the request-path streamed restore, four new settings, LRU/budget/free-space, no
cudaHostRegister). It was validated in two short isolated windows: forced-pressure file park write
works (250k conversation, 3,636,601,128 B file, 4.5 s at ~0.8 GB/s, tier peak 10.16 GiB under the
12 GiB budget), a streamed restore from a pmem park works (5.17 s, checkpoint reuse, take+unlink),
corrupt-park refusal works (pass-1 checksum refusal, clean reread, identical answer), and the RAM
park path is unchanged. The ordinary-turn "park now -> next turn restores" flow was **not** taken:
the parked file carries only the deepest prefill-chunk checkpoint and that candidate did not match
the next turn's prompt, so the request reread the prompt (152.6 s at 239k) instead of restoring;
the probe's own sequencing bugs were fixed between windows, and the remaining gap is engine-side
checkpoint-set policy. Enabling was therefore rejected for now; the patch is **deployed dormant**
(no `--conversation-park-*` flags, zero behaviour change) in generation 106. Follow-up before
enabling: log the file candidates (live/deepest/cvec/resume) and store all chain checkpoints in the
ParkedFile metadata (or synthesise a turn-boundary checkpoint), and prefer a file match over a full
reread when a file candidate exists; then one 5-8 min re-window. Risks if enabled: 4.5 s blocking
capture on the request thread per 250k park, ~3.6 GB of Optane writes per park, and DCPMM thermal
headroom (media 77 C, controller 83 C vs 85 C critical).

### Deployment

Generation 106 deployed from the repo tree (engine `/nix/store/2fa52rqzh86szmfmrqwkd0lziwj2da0s-...`,
system `/nix/store/idsww8aa...`); `tiberius-strata` healthy on both doors, telemetry timer active,
unlock verified in the boot log and nvidia driver healthy, pmem tier off. A systemd-boot EFI variable
(`LoaderEntryDefault`) was found overriding the regenerated `loader.conf` and pinned to generation
104; it was set explicitly with `bootctl set-default` before the successful boot, so future
generations take effect on reboot as intended.

## Round 8 results (2026-11-05)

Goal: make the ordinary-turn pmem park actually restore on the next turn, then enable the tier if
it passes; plus the Unsloth assessment. No hardware change.

### pmem park-spill checkpoint match: fixed, validated, enabled

Two windows on top of the dormant round-7 patch found the real cause. The parked file carried only
the deepest checkpoint, and even "strictly shorter" was not enough: the last chain checkpoints
(239,184 / 239,190 tokens) sit at the old prompt's junction with the reply, and appending a turn
re-tokenizes it, so they are not prefixes of the next prompt. The engine itself showed the stable
choice - at the continuation it reused the 225,280-token checkpoint. Fix (patch `1f2393f2`): the
park saves the deepest chain checkpoint **at least 1024 tokens below the live state** (falling back
to the deepest shorter one, then the writer's rule), stores the whole chain as metadata only
(session format v1 untouched), matches only the saved/live states the streamed reader can rewind
to, and prefers a file candidate over a full reread when the request would otherwise read from
token 0. `STRATA_PARK_DEBUG=1` logs the candidates and the choice.

Validated in a 7-minute isolated window: 250k ordinary-turn park -> next turn restored **225,280**
tokens from the pmem file in **5,149.5 ms** (prompt line 225,280 reused + 13,917 read in 19.4 s, vs
152.6 s reread), continuation sha identical to the live-path re-ask (`e9f339a7...`); park writes
4.48-4.50 s / ~3.636 GB each, 2 files/7.27 GB on disk; corrupt newest `.park` -> pass-1 checksum
refusal + clean reread with the same sha, no half-restored state; RAM-park regression clean, zero
files; Optane 40 G free PRE/POST. VmHWM not isolatable (the 250k prefill set it) - the streamed
restore's host peak is the ~270 MiB class measured in round 5.

**Enabled in generation 107** (engine `gci3izr...`, patch `1f2393f2`): engine args
`--conversation-park-dir /optane/strata-data/parks --conversation-park-mib 6144
--conversation-park-slots 4 --conversation-park-min-free-mib 4096`, plus an `ExecStartPre` that
pre-cleans stale `*.park` files (boot re-admission is not implemented). Note the 6 GiB cap holds one
long 250k park plus short ones; two concurrent long chats would evict the older (8 GiB would hold
both). Residual costs: 4.5 s blocking capture on the request thread at a switch, ~3.6 GB written per
250k park (~0.8 GB/s effective), Optane write volume/thermal headroom (media 77 C baseline) - the
telemetry lane watches this; disable by dropping the four flags.

### Unsloth Dynamic V3.1: assessed, not adopted

The 2026-11-02 Unsloth update is a **GGUF quantization recipe** (better imatrix/calibration and
per-layer dynamic quantization; their Qwen3.8-Flash-Next table claims, e.g., UD-IQ3_XXS 82.0 GB /
85.4 % top-1 and UD-Q2_K_XL 78.9 GB / 82.7 % vs. their competitors' quants). It is not a new model
and not a drop-in for this lane: `tools/iq_pack.py` supports the engine's i-quant family
(IQ1_M/IQ2_*/IQ3_*/IQ4_*/Q2_0/Q4_0/Q4_NL/Q8_0) but not the K-quant UD mixes, the lane's total
footprint is already ~82 GB on the 124 GB Optane with 40 GB free (an 82 GB download plus rollback
pack does not fit without moving the retained source GGUF), and the claimed +15 % is against
competing quants, not against the current GSQ/RCO IQ3_S pack. The recommended non-thinking sampling
already matches the lane's served defaults, and MTP does not apply (DFlash2 drafter). Only
UD-IQ3_XXS is a technically plausible same-size experiment; it would need a pack rebuild, a
DFlash2 question (drafter was fitted to the current pack), and 2-3 paired eval320 passes to clear
the 5.9 % harness floor before adoption. Recorded with a full experiment plan in
`unsloth-dynamic-v31-assessment.md` and task-24; not adopted now (quality is not the current
bottleneck, prefill was and the unlock improved it).

### Deployment

Generation 107 deployed from the repo tree (system `/nix/store/3i99wsnkmq3jmiy975k51l9dnmhkz2b4-...`)
and verified: engine args carry the four park flags, `/optane/strata-data/parks` created, service
healthy on both doors, telemetry timer active, no Xid, unlock still active from the initrd. The
persistent systemd-boot `LoaderEntryDefault` EFI variable again pointed at the previous generation
and was re-set with `bootctl set-default nixos-generation-107.conf` so a reboot keeps 107.

### Round 8b: CUDA stop-bound port and per-window telemetry (generation 108)

Two engine patches, deployed as generation 108 (engine `gwhnf6m...`, patch `6f44477`):

- **CUDA port of upstream #4677** (behaviour): the `STRATA_USE_HIP` guards around `serve_stop_bound`
  are gone, so on CUDA a verify window that would commit past an EOS inside it commits up to the
  stop token; `STRATA_SERVE_STOP_BOUND=0` still disables it. Validated A/B: five requests with the
  bound on vs off gave identical answer shas and emitted token counts (exact/empty/one/short/p50),
  and the short prompts exercised the path (1-2 clipped windows, rows counted).
- **Per-request WSTAT telemetry** (counters only): one stdout line per finished request carries DAX
  rotations, prompt-path borrowed bytes, verify windows/rows/accepted and windows-by-size, stop-bound
  clips, prompt-read seconds and the prefill phase timeline (when STRATA_PREFILL_TIMING=1); the serve
  layer parses it on the solo path, the control/drain paths and the batch path, aggregates it into
  totals and exposes nine `strata:*` families plus the verify-window-tokens histogram and
  `prefill_phase_seconds_total{phase=...}`. `/metrics/prometheus` and the JSON `/metrics` both carry
  it; older engines emit no WSTAT and the endpoints are unchanged. `/metrics` payload ~6 KB, public
  safe (numbers only).

Validation found and fixed two server/telemetry bugs before deployment: the WSTAT line was stashed
and then wiped by `_parse_done` (now attached by `_parse_done`), and the legacy `/metrics/prometheus`
path was not extended (fixed additively); the rotations counter was decode-only because its baseline
was taken after the prompt read, so it now reports the engine's cumulative rotation count (the
per-request delta is derivable from two scrapes; the probe's histogram-count==requests expectation is
wrong - the histogram counts requests that actually had verify windows). Final window: all nine
families present and monotonic, rotations delta 17 == engine-log 17, borrow 12.29 GB, stop-bound
counters 1 window/2 rows, phases emitted, A/B answers identical (`same_answers: true`).

## Round 9 results (2026-11-05): Unsloth Dynamic V3.1 switch

Question: the Unsloth Dynamic V3.1 chart shows UD-IQ3_XXS at 82 GB scoring 99.9 vs 99.0 average
recovery for Qwen's GSQ-RCO IQ3_S at 83.7 GB, and UD-IQ2_XS at 76.5 GB scoring 99.4 - i.e. at equal
size a small quality edge, and at lower size parity-or-better. Both technically plausible arms were
built and measured.

**Compatibility:** the GGUF headers show UD-IQ3_XXS uses IQ3_XXS/IQ2_S/IQ4_NL/IQ4_XS/Q2_0 experts
and Q6_K/Q8_0/F32/BF16 dense/PLE tensors, all in the engine's supported families; UD-IQ2_XS uses
IQ2_S experts + IQ4_NL downs (3 shards). `tools/iq_pack.py --experts-bin --compat-bf16` produced
packs cleanly (the Q8_0 hc/projection tensors the engine reads as BF16 need the compat conversion;
compat-bf16 rounds only those small tensors). Disk staging: the old source GGUFs/PLE were deleted
to make room (redownloadable), old artifacts were archived to pius where not rebuildable, and
`/data` + Optane were reorganized around the 82/76 GB downloads.

**Arm A - UD-IQ3_XXS** (experts.bin 46.84 GiB, 7,660 slots): eval320 3 passes 60.0/61.6/59.4 % vs
baseline 58.1/59.7 x (mean +1.4 pp); same-index paired +1.9 pp both passes, pooled p=0.111 - inside
the same-stack floor, not significant. Speed: +1.6 % P1, +0.3 % P8K, +0.8 % P27 (neutral), L-live
read +2.7 %, decode 107-127 tok/s (in-session drift), DFlash2 acceptance -8..-13 pp on some cells.
Two DAX host-registration failures per prompt pass (5.93 GiB windows, 46.84 GiB pack) and 9 rotation
windows/pass; ~0.0-1.4 MB extra file read per cell, so the cost was small but real.

**Arm B - UD-IQ2_XS** (experts.bin **39.38 GiB**, **8,898** slots): eval320 58.1/58.8/60.0 % vs
baseline 58.1/59.7 % (mean -0.2 pp; p≈1.0) - quality statistically indistinguishable from the old
pack, and every pass faster to evaluate (337/333 s vs 386/393 s). Speed: **P1 -14.8 %, P8K -11.5 %,
L-live read -16.3 %, decode +4.1 %, P27 +1.2 % (neutral)**; clean same-engine PPL cell -24.7 %
read / +21 % decode vs IQ3_S; streamed expert bytes -19/-16/-8/-31 %. **Zero** DAX registration
fallbacks and 7 rotation windows/pass (the 0.82 GiB layer blobs fit the 6.00 GiB window); expert
cache +1,039 slots. Costs: DFlash2 L-live acceptance 85 % vs 98 % (decode still faster), greedy
answer identity changes (different quant), and in-session greedy drift on P1/L-live.

**Decision: arm B adopted** (quality parity within the measured floor, clear speed gain, less DAX
pressure, more cache slots); arm A remains the quality-first option if a later eval settles a real
edge. Deployed as generation 109: `/data/strata-models/UD-IQ2_XS/{shard1,shard2}`, PLE shard 3 under
`/optane/strata-data/ple/`, pack `/optane/strata-data/packs/ud-iq2_xs`; the lane config gained
`midShards`/`pleShard`/`pleFile` for 3-shard models (native dir links all shards) and the API
`model_name` was kept unchanged for client compatibility at the switch; renamed 2026-11-19 to name
the pack (`strata-model-name.md`). Verified: service healthy on both doors, expert
cache 8,898 slots, warm request answers, telemetry active, no Xid, boot default re-set to 109.
Follow-ups: DFlash2 drafter refit for the UD pack; rollback procedure (old source GGUFs/PLE are
redownloadable, old pack rebuildable from them); coder lane needs its own PLE again. Full data:
`/data/round9/` (baseline, iq3_xxs, iq2_xs; item-level JSON + compare summaries), speed reports in
`/tmp/strata-tune/round9-speed-results.md` and `/tmp/round9-speed/`.

**Rollback source (verified 2026-11-05):** old model is
`ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF`, `IQ3_S/Qwen3.8-Flash-Next-GSQ-RCO-IQ3_S-00001-of-00002.gguf`
(54,817,524,224 B, LFS sha256 `4c1eb2ce...`) and
`...-00002-of-00002.gguf` (28,800,138,432 B, LFS sha256 `316b46f3...`; this shard is both the old
shared PLE and the coder lane's PLE). Rollback: download both, put shard 1 under
`/data/strata-models/IQ3_S/` and the PLE under `/optane/strata-data/ple/` under the old name, revert
`lanes.general` (named `lanes.iq3-s` before 2026-11-19; pack `iq3_s`, models `IQ3_S`, old shard1, no
`midShards`, old `pleShard`/`pleFile`),
rebuild `pack` with `tools/iq_pack.py --gguf <shard1> --out /optane/strata-data/packs/iq3_s
--experts-bin` (GSQ does not need `--compat-bf16`), and `nixos-rebuild switch`. The coder lane stays
unavailable unless its own IQ1_M pack/model are restored as well; the module assertion documents
both.

### Round 10 follow-ups (2026-11-05, same day)

- **DFlash2 knob sweep on UD-IQ2_XS** (the pack's L-live fresh acceptance fell 98.1 % -> 85.1 %):
  eight fresh-engine starts with the live config and only `--spec`/`--draft-conf` changed. The
  acceptance loss is a **spec-window effect, not a confidence one**: at spec 6, lowering draft-conf
  0.8 -> 0.65 -> 0.5 does not recover acceptance (85.1 / 84.4 / 84.1 %) and costs 0.5-1 % decode;
  `--spec 4` at conf 0.8 recovers acceptance to **91.6 % (+6.5 pp)** but decode is **-1.2 %**
  (109.65 -> 108.35 tok/s); `--spec 8` lowers acceptance further. Nothing beat the deployed
  (spec 6, draft-conf 0.8) decode, and all variants generated the identical L-live text
  (51d49971...), so **no change was adopted**; a drafter refit could recover some decode but is not
  worth it for the measured window. Report: `/tmp/strata-tune/round10-sweep-results.md`,
  `/data/round10/`.
- **Coder lane**: marked unavailable in the module with an assertion carrying the restore procedure
  (its pack, model shards and the shared old PLE were removed by the round-9 switch); rollback
  source and rebuild steps for the old IQ3_S pack are recorded below.
- **Rollback source verified** (see above): `ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF` IQ3_S
  shards with their LFS sha256s, plus the `iq_pack.py` rebuild + lane-field revert steps.

### Round 11: prompt-chunk screen on the smaller pack (2026-11-05)

The UD-IQ2_XS switch made the expert pack 7.5 GiB smaller, so the deployed chunk
`--prefill 28160` was re-screened (the real hindsight traffic is 19-38k tokens, where a 28,160 chunk
means two chunks and two pack streams). Result: **no win** - the engine halves a larger request at
startup with the explicit log line `prompt chunk 56320 -> 28160 tokens so its buffers fit in every
expert cache`, so 56320 runs as the identical 28160 and 112640 clamps the same; the measured 38k
read was +1.8 % (noise), 26k -4.2 % (noise), 4k +4.2 % (noise) on single runs. **`--prefill 28160`
stays.** Side finding for hindsight: a repeated 38k conversation restored one chunk-level checkpoint
(reused 28,160) and read the remaining 9,862 tokens in 11.1 s instead of 29.0 s.

The window also spot-checked the pmem conversation park with the new pack: two short conversations
parked (3,554/4,259 tokens, ~140-163 ms) and restored on repeat (reused 3,470/4,245 tokens, ~57 ms,
zero invalid-snapshot lines) - the tier works on UD-IQ2_XS. Note for the record: the restored 3,477-
token conversation generated a different continuation than its live first answer (78 -> 64 tokens;
the 8-token P1 case was identical). That is the checkpoint-continuation state effect (the restore
replays from a 3,470-token checkpoint rather than the exact live state), not a half-restored
session; it is the same class as the eval pass-state flips and worth knowing when a parked
interactive conversation is restored - answers can differ from an uninterrupted run. Report:
`/tmp/strata-tune/round11-chunk-screen.md`, `/data/round11/`.

### Round 12: DFlash2 refit value bound (2026-11-05)

To answer whether a drafter refit is worth pursuing, one isolated window ran the live config with
`drafting: "off"` (the serve layer then omits DFlash2; the engine's built-in suffix/lookup drafting
still runs). L-live decode fell **113.85 -> 62.3 tok/s**, so DFlash2 already buys **1.83x decode** on
the UD pack; with acceptance 85.1 % and its 6-token windows 80-95 % full, a perfect-acceptance
drafter could add at most ~+15 % decode on average (+25 % on the best run) and zero on prefill.
**No refit**: the effort is a training/calibration project for a single-digit-to-mid-teens decode
ceiling, and prefill (the real bottleneck) is untouched. Report:
`/tmp/strata-tune/round12-draftoff-bound.md`, `/data/round12/`.

### Round 13: engine pin bump to v0.2.11 (2026-11-05, generation 111)

v0.2.11 (`c3b3f503`, engine 0.1.57) shipped on 2026-11-05 and was taken over the v0.2.10 pin
(`ffa80d73`, engine 0.1.56).  **What selects for this lane:** the Q5_0 expert-dot fix (upstream
aa678f10) - the deployed UD-IQ2_XS pack's expert layer 4 is the only one of 48 whose down type is
Q5_0 (`native_experts.txt` d_type=6), and upstream measured the whole-expert error falling
2.1-3.1e-2 -> 1.2e-2 (the other down types' level) - plus the 0.2.11 serve-layer changes (chat
files, agent-turn takeover, the 60 s stream-write timeout, the bounded console queue, the drafter-less
retry of an OOM start, the activity lease).  **What does not select:** the K-quant MMQ prompt kernels
and the 32768-token `--prefill auto` ceiling (compute capability 8.0+ only; the module's explicit
`--prefill 28160` is untouched), the all-cards split engine / two-card prompt path / layer-split
trim-and-spill walk (multi-GPU only), the gfx12 Radeon defaults (not built), and the FP16 weight
cache (batch slots only; this lane runs none).  The discrete-CUDA CPU/upload share rule (ceiling 0.95,
k following the pool rate) feeds PcieAuto only, and `STRATA_PCIE_FRAC_DEFAULT=old` still keeps that
refinement off - the start-up probe still logs `PCIe probe: 12.2 GB/s ... -> pcie_frac 0.34`.

Rebase: the engine hunks (expert_source.cpp, prefill.cpp, all of generate.cpp) applied with no fuzz
and `no-web-ui.patch` / `avx512-bw-tier.patch` applied cleanly.  `serve/server.py` took two "keep
both" conflicts (0.2.11's per-line progress reset in the two wait loops beside the WSTAT parse;
0.2.11's `if not admission_rejected:` guard around the per-request totals, with the WSTAT aggregation
re-indented inside it) and one added hook: 0.2.11 finishes non-streaming requests in the `finally`
drain loop, which consumed the WSTAT line without parsing it - the probe found the telemetry silently
absent from /metrics (answers unaffected), and the drain loop now parses WSTAT before DONE.  The
build-time greps grew 42 -> 48 (the new share gates and the `!pf_old` gate, the W16 batch gate,
`prefill_auto_bare`, nv_defaults' MMQ gate, vram_fit's `kv_fixed` hook).

Validation (isolated port-8099 window, production stopped and trap-restored; deployed 0.1.56 vs
0.1.57, same config/pack): 4,252-token read 8.60 -> 8.68 s (+0.9 %), 26,134-token read
21.78 -> 21.39 s (-1.8 %); per-request totals 2,155 -> 2,184 tok/s prefill and 65.3 -> 68.0 tok/s
decode (5 requests each, one interleaved run - inside the box's ~3-5 % spread).  All four speed-cell
answers differ (the Q5_0 layer, expected).  eval320 (frozen protocol) 188/320 = 58.8 % against the
round-9 UD-IQ2_XS 0.1.56 baseline 186/320 = 58.1 %: discordance 10/320 (3.1 %), McNemar p = 0.754,
risk difference -0.62 pp [95 % CI -2.50, +1.25] - no detectable quality change.  Deployed as
generation 111 (engine `/nix/store/x4jdmab9180v31xc5fx725py1z9mv6l7-strata-engine-0.1.57`, system `/nix/store/gb91d6ap0z57ad397xzapx8ny50l67yc-nixos-system-tiberius-26.05.20260927.cf5e765`); service healthy on both doors and
the nine WSTAT families verified after the switch.  Rollback: revert the pin and the three patch
files to the previous commit, rebuild, `nixos-rebuild switch`; the pack/model are untouched.

### Round 14: engine pin bump to v0.2.12 (2026-11-09, generation 112)

v0.2.12 (`146df3c4`, engine 0.1.58) was taken over the v0.2.11 pin (`c3b3f503`, engine 0.1.57).
The release upstreamed the local AVX-512 work (PR 5120, `f000d4a4` + `7e3fae57`: the VBMI-free q2
unpack, `cpu_vbmi_ok` / `cpu_vnni_ok` / `q2_rows_512_ok`, and the tier OPT-IN below VBMI through
`STRATA_VNNI_TIER=1`).  `avx512-bw-tier.patch` therefore shrank to its compile-time half (the
unconditional VBMI-free unpacks in `expert.cpp`, `-mavx512vbmi` removed from
`expert.cpp`/`iq_avx512.cpp`/`nvfp4_avx512.cpp` in both CMakeLists; the trellis TU unchanged), and
the module sets `STRATA_VNNI_TIER = "1"` to keep the tier.  New kernels that come with it here:
`q50_512` (layer 4's one Q5_0 down; its first-use bit check passed silently) and `iq4xs512` (inert:
the pack has no gu type 23 on any of its 48 layers).  What does not select: the 8.0+ MMQ / prefill
auto ceiling, the multi-GPU split paths, the gfx12/gfx1151 tables, the opt-in ADAPT_FETCH,
SELECT_TWO_PASS, IQ4_W4A8, DF2_GATE and IQ512_FUSED paths, the file tier's honest re-check
(`STRATA_UNBUFFERED_LOAD=0` returns first), and the Auto/tuned DFlash2 paths (named drafter; tuned
pack needs >= 12,000 slots).  Serve layer: tool-call/parser fixes; the request-accounting rewrite
added no fifth DONE path, so all four WSTAT readers still parse it.  Rebase: six "keep both"
conflicts in `generate.cpp` (the in_flight marks in the plans split, the AdaptGate `counter` field,
STRATA_FOLLOW vs the stop-bound port, fetch_log vs the racc counter), `serve/server.py` clean; the
patch sequence re-applies byte-for-byte.

Gate: the staging window exposed a harness defect - gate1 (2026-11-08) derived both arms from the
gen-111 config, so its new arm ran the AVX-2 CPU tier instead of the deployed one ("CPU expert
kernels: AVX-2" in its log); it is archived at `/data/bump/gen112-gate1/` with a note and was not
used for the decision.  Gate2 (2026-11-09, each arm's own deployed config, production down 8m51s)
is the record: new 0.1.58 and old 0.1.57 have bit-identical greedy answers on all four speed cells,
walls -1.4..+0.2 %, totals 2,218.9/68.1 vs 2,199.2/67.8 tok/s prefill/decode (inside the box's
spread), eval320 187/320 vs the 188/320 gen-111 baseline (McNemar p = 1.0, RD +0.31 pp
[-1.88, +2.50]), and all nine WSTAT families populated after the warm request.  Deployed as
generation 112 (engine `xwq69054...`, system `v5c0fx5s...`); warm "ready.", WSTAT after the switch,
boot default 112, no Xid.  Incident: the tiberius-native build OOM-killed the production engine once
(2026-11-08 10:18:09 UTC - a `cudafe++` CUDA compile on the 7.4 GiB box); it auto-restarted on 0.1.57
in ~87 s, and rebuilds on this box should cap parallelism (`--cores 8 --max-jobs 2`).  Open:
whether 0.2.12's routing-aware look-ahead runs in this config is unmeasured; q50_512/iq4xs512
performance is not separately measured (the gate shows no regression overall); the agent lane can
move with the tool-call/parser fixes.  Artifacts: `/data/bump/gen112/`, `/data/bump/gen111/`.

#### Post-bump option screen on 0.1.58 (2026-11-09; measurement only, no config change)

Three isolated port-8099 windows (08:12-08:22, 08:24-08:33, 08:34-08:41 UTC, production
trap-restored each time) screened every 0.2.12 opt-in that can select on this lane, each arm a
fresh isolated engine from the gen-112 config (deployed env `STRATA_VNNI_TIER=1` + one override),
same protocol as the bump gate: P1 = 4,252-token prompt, P2 = 26,134-token, 2 reps each, greedy
256, thinking off; a warm request ahead of them.  Artifacts: `/data/bump/measure/` (per-arm
results JSON, `prom-*.txt`, engine logs, `window{,2,3}.log`) and archived under
`/data/bump/gen112/measure/`.

**Result: none of the 0.2.12 opt-ins buys anything measurable on this lane; nothing was adopted.**

| arm (vs deployed env) | decode (ms/tok) | reading |
|---|---|---|
| base / base2 (no profile) | 67.1 / 68.5 tok/s (14.90 / 14.60 ms/tok); window-2 repeat 68.7 / 67.3 | run-to-run noise ~±1.5 % when the answer stream differs |
| `STRATA_VNNI_TIER=0` | 70.5 / 70.6 tok/s (14.19 / 14.16) | apparent +4 % is a STREAM artifact: the AVX-2 tier answers differ (rounding), so draft acceptance is 82.8 % vs 78 %; profiled arms show the CPU pool is identical (below) |
| `STRATA_IQ512_FUSED_MAX=8` (new fused gate/up rows) | 68.3 tok/s (14.64); identical answers to base on the fresh cells | no effect: too few CPU-pool rows to exercise it |
| `STRATA_ADAPT_FETCH=1` (new) | 65.8 / 66.5 tok/s (15.19 / 15.03) | -2..-4 %, and it CHANGES answers (first-request sha `ec55e8…` vs `aed6d7…`): admission alters residency -> rounding |
| `STRATA_DF2_GATE=1` (new; default row_ms 3.0, Mac-tuned) | 64.6 / 64.5 tok/s (15.47 / 15.50) | reproducibly -5 %: windows widen (drafts offered 46 -> 91-105/request) and acceptance falls 91 % -> ~56 % |
| same, `STRATA_DF2_ROW_MS=6` / `=5` | 68.5 / 69.0 tok/s | neutral / within noise at best; no gain |
| `STRATA_UNBUFFERED_LOAD` deleted (0.2.12 honest re-check path) | P1 read 7.15 s (vs 7.12-7.24 base), P2 read 21.61 s (vs 21.58/21.66) | no effect at all: without `--resident-budget-gib` (`hostTierGib=0` -> `--mmap-experts`) the file-tier buffering decision is not applied (`generate.cpp:7743`), so the module's pin is INERT on this lane |
| `STRATA_VERIFY_PROFILE=1` + `STRATA_ROUTE_STATS=1` (new measurement knobs) | 63.1 tok/s vs 67-68.7 unprofiled | cost ~6 % decode - keep them off in production; they work and gave the window breakdown below |

Profiled arms (window 3) isolate the CPU tier cleanly - pool+plan per decode window is the SAME with
the VNNI tier, AVX-2, and the fused rows, and the profiled baselines repeat to 0.5 %:

| per-window stage metric | pbase (tier on) | ptieroff (AVX-2) | pfused (fused on) | pbase2 |
|---|---|---|---|---|
| P1 rep2 (113 gen): pool+plan | 4.020 ms | 4.016 ms | 4.013 ms | 4.043 ms |
| P2 rep1: pool+plan | 3.509 ms | 3.667 ms | 3.514 ms | 3.611 ms |
| P2 rep2: pool+plan | 3.158 ms | 3.231 ms | 3.115 ms | 3.172 ms |
| wait for the GPU (same cells) | 22.28-22.53 ms | 22.41-23.09 | 22.36-22.69 | 22.36-22.64 |

Mechanism: the route prior keeps the decode at a 99.2 % expert-cache hit rate, so the CPU expert
pool sees ~0.8 % of the window's expert rows; "pool + plan" is dominated by planning, not by the
512-bit kernels - which is why the AVX-512 tier (ab18's ~5 % CPU-pool win was measured at the
pre-route-prior 68-80 % hit rates), q50_512 and the fused rows all measure as zero today.  The new
kernels are effectively dormant on this lane, not expensive; keeping the tier costs nothing.

Two methodology notes for future windows: (1) answer streams are not reproducible across arms -
identical configs can differ on the second fresh request and on warm-cache repeats (residency and
refill state move the rounding), so cross-arm decode tok/s must not be read as a kernel delta; when
the output IS identical (for example the first request after an engine start), decode timing is
reproducible to under 0.5 % (93 tokens: 1,464 / 1,466 / 1,465 ms).  (2) An arm that changes output
must be judged end-to-end on its own stream - which is what the table above reports - and the
profiled `pool + plan` / `wait for the GPU` split is the clean way to attribute a delta.

### Round 15: engine pin bump to v0.2.13 (2026-11-09, generation 113)

v0.2.13 (`d2f0964`, engine 0.1.59) was taken over the v0.2.12 pin (`146df3c4`, engine 0.1.58).
The release is mostly app/Control and Qwen4 groundwork (per-card DFlash2 defaults on Strix Halo and
Blackwell cc 12.0, the Strix Halo Windows reserve floor, Intel Arc's fixed-order bf16 products, the
app's start time, the signed feed's model list and the `strata-q4-<shape>` engines); upstream
publishes no speed claim for 0.1.59 on this card.  **What selects for this lane:** on Linux CUDA,
0.1.59 defaults `STRATA_HC_Q8=1` when the native dense GGUF carries its hyper-connection projections
as Q8_0 (Unsloth UD-* files) - the deployed `UD-IQ2_XS` dense file does, so the lane moves from the
BF16 read 0.1.58 used to the file's own Q8_0 bytes.  The gate carried a third diagnostic arm
(`STRATA_HC_Q8=0`) that was bit-identical to 0.1.58 on all four speed cells, proving that switch is
the bump's only answer-affecting change.  The module pins `STRATA_HC_Q8 = "1"` as adopted.  **What
does not select:** the launcher-env stacks (the GDN pair moved into the engine as the same
`STRATA_GDN_TC=1`/`STRATA_GDN_CONVL2=2` values 0.1.58's serve set, and `STRATA_GDN_TC` is arch-gated
off on sm_75; the parallel stack needs 2+ batch slots, this lane runs one and pins the GDN pair
explicitly now), the #5327 arena file-cache credit (`ArenaExpertSource` only; this lane runs
`--mmap-experts`/`FileExpertSource`), the Auto-only DFlash2 card tables (named drafter, Turing card,
stock pack), the geometry default (`flash_next`, unchanged build), and the removed
`STRATA_DF2_GATE`/`STRATA_DF2_ROW_MS`/`STRATA_MMVQ_*`/`STRATA_GR_Q32_PL`/`STRATA_METAL_*` opt-ins
(unset here).  The serve layer's tool-call parser is now picked from the chat template - outside the
gate's cells, so the agent lane's answers can move with it.

Rebase: **zero hunk conflicts in all three patches.** Every 0.2.13 change in the files they own
(generate.cpp's compiled geometry and engine-side defaults, prefill.cpp's geometry widths,
expert_source.cpp's #5327 credit, serve/server.py's parser selection and launcher-env removal) sits
outside their regions, so the bodies are unchanged - only hunk offsets and `index` blobs were
refreshed.  `avx512-bw-tier.patch` was retargeted for the build reorganisation: root
`CMakeLists.txt` is now split into `cmake/backends/*.cmake`, the per-TU kernel flag lists moved
verbatim into `cmake/backends/cpu.cmake`, and the package's postPatch guarantees follow them (with
new sycl mirrors); `expert.cpp` is unchanged upstream.  WSTAT audit unchanged: four `_parse_done`
sites, all four parse WSTAT before DONE, no fifth finisher.  The package now builds against the
vendored `third_party/strata-ggml` (llama.cpp `3cf03257`, same pin) with no llama.cpp fetch, and
asserts both the vendored pin and the `flash_next` geometry default in postPatch.

Gate (isolated port-8099 window, each arm from its own deployed config; 12m14s production down
because of the third arm and its 346 s eval320 pass; the first two attempts aborted before any engine
start on stale paths in the wrapper and the trap restored production in ~43 s each):
- start config: new 9,140 expert slots (14.64 GiB VRAM) vs old 8,898 (14.26) - the 0.63 GiB Q8_0
  hyper-connection copy replaces the BF16 copy and frees 0.39 GiB for the cache (+242 slots);
  both arms keep the 6.00 GiB DAX window over the 39.38 GiB pack, `pcie_frac 0.34`, elastic K/V
  16,384/262,144, DFlash2 stock pack `--spec 6 --draft-conf 0.8`; engine up 42 vs 39 s.
- speed: within the box's spread - P1 4,252-token read 8.611 vs 8.715 s, P2 26,134-token read 21.404
  vs 21.342 s; per-request totals 67.3 vs 67.4 tok/s decode and 2,188.2 vs 2,189.4 tok/s prefill.
- answers: new differs from 0.1.58 on 4/4 cells; new0 (=0) is bit-identical on 4/4.
- quality: eval320 189/320 = 59.1 % vs the gen-112 baseline 187/320 = 58.4 % (discordance 10/320,
  McNemar p = 0.754, RD -0.62 pp [-2.50, +1.25]) - no detectable change, so HC_Q8 is adopted.
- WSTAT: all nine families populated after the cells (rotations 13, borrow 69.48 GB, windows 215,
  rows 209, accepted 167, stop-bound 2/2, prompt seconds 27.78).

Deployed as generation 113 (engine `7nk2w1ip...0.1.59`, system `v14n6p6n...`; switch 18:10:39 UTC):
both doors, the warm completion, the nine WSTAT families, 9,140 slots, the pinned HC_Q8/GDN env,
boot default `nixos-generation-113.conf` and no Xid all verified.  Rollback: revert the package files
and `profiles/nixos/strata.nix` to `0822608`, rebuild/switch; emergency = boot generation 112.
Artifacts: `/data/bump/gen113/` (results, engine logs, proms, eval, window/build/switch logs,
`paths.txt`, source tree, gcroots).  Open: HC_Q8's effect on long-context sessions (250k) was not
measured - only the P1/P2 cells, where the Q8_0 read is 0.63 GiB of a path the route prior keeps off
the critical path; the new tool-call parser's effect on the agent lane is outside the gate; and
upstream did not measure 0.1.59 speeds on the final release packages.  Follow-up candidates, in
measured-cost order: (1) re-sweep the `--prefill 28160` intercept - it was chosen at 0.1.40 against
the old borrow accounting, and the Q8_0 read now frees 0.39 GiB / +242 slots, which moves where a
chunk halving lands; (2) screen HC_Q8 on a long-context cell (P27 or a 100k+ session), where the
0.63 GiB verify read is a larger share of a window than on P1/P2; (3) if answer drift is ever
tolerated, challenge the pinned `STRATA_GDN_CONVL2=2` against `=1` (upstream's "not bitwise on
CUDA" pair; =2 has been running since the 0.1.58 serve stack, so this is a provenance check, not a
new default); 0.2.13 added no new runtime opt-ins for this backend (the only added env surface is
`STRATA_ARENA_FILE_CACHE`, inert on this `--mmap-experts` lane, plus the build-time
`STRATA_GEOMETRY*`/`STRATA_BUILD_DSV41`), and retired the 0.2.12 switches the gen-112 screen had
already rejected.

### Round 16: engine pin bump to v0.2.15 (2026-11-16, generation 114)

v0.2.15 (`c7757280`, engine 0.1.61; the release ships 0.1.60) was taken over v0.2.13.
Eight rebase resolutions (the park-pool block, the parking condition and the stop-bound
block - upstream 0.1.60 makes this patch's CUDA port redundant), `no-web-ui` clean, the
sycl flag lists retargeted; the build pins `-DSTRATA_MMQ=OFF` and
`-DSTRATA_OWN_CPU_QUANT=ON`.  Gate: up 42 s vs 45 s, 9,156 slots vs 9,140, P1/P2 fresh
reads -1.1 % / -1.6 %, eval320 192/320 vs 193/320 (McNemar p = 1.000) - no detectable
quality change.  Follow-up: `STRATA_PARK_SEGPOOL_MIB=0` pinned (512 MiB of image budget
for 32 ms on the 26k park) and `--prefill 28160` kept (the 56320/22528 screen was flat).
Full record and numbers: `../VALIDATION.md` §"Generation 114"; artifacts
`/data/bump/gen114/` + `/data/bump/window5b.log`.

### Round 17: DFlash2 copy-heavy lookup screen (2026-11-23)

The last untested acceptance lever was prompt lookup on copy-heavy text: `--lookup-max-t` defaults
to 0 with DFlash2 (`lookup_default.hpp`), so the deployed lane runs only the 8-row
DFlash2/suffix window, and the one DFlash2 lookup measurement was prose (round 10: 12 rows,
-1.4 %). A copy cell was the only remaining place where a wider lookup window could plausibly pay.

Harness: new `/data/ab53.py` (the ab25 flow) on the isolated port-8099 engine, 0.1.63 root,
`/data/ab53-base.json` = the deployed config with the conversation spill tier off. Three cells from
`/data/real-corpus.txt`, greedy, two reps: **copy** 11,538-token prompt + 512 generated
(`ignore_eos`), **edit** 5,748 + 384 (markdown -> plain text), **prose** 4,252 + 256. Arms base /
`--lookup-max-t 12` / `--lookup-max-t 9`, counterbalanced base, lk12, lk9, lk9, lk12, base.
Window 09:29:39-09:36:41, production restored by the trap and healthy at 09:37:25 (46 s engine
start).

| arm | copy | edit | prose |
|---|---|---|---|
| base | 97.5 % (436/447), 111.0 / 123.9 tok/s | 96.6 / 94.6 %, 113.7 / 117.5 | 86.5-89.7 %, 63.8-71.3 |
| lk12 | `native ERR dflash2: draft rows out of range` (HTTP 400) | not reached | not reached |
| lk9 | same error | not reached | not reached |

Prose ends at EOS (82-83 generated), so its tok/s is a short-answer figure, not a steady-state
one; the copy and edit cells run to the fixed token count. The two base arms are byte-identical
on copy and edit (sha `b112adf5...`, `de586710...`); prose drifts by one token between arms
(sha `88ea782a...` / `efb58dca...`, 64-71 tok/s), which is the harness's spread on that cell, not
an arm effect.

The wide arms are **not slower - they do not run**. The engine starts, logs
`--lookup-max-t 12: MTP windows up to 6 tokens, window sizes 1,2,3,4,5,6,7,8,12`, captures the
12-token window (27.3 ms, 565 MiB free), and then the first copy request ends the draft path with
the error above; serve returns 400 and the driver stops the arm. Same at 9. The DFlash2 block is
8 rows (anchor + 7 masks); a longer window would have to combine that block with lookup drafts in
one verify pass, and the draft call ends with the error above before any such split happens - so
**9+ row windows are unsupported with DFlash2**, not expensive. `--lookup-max-t 8`
is a no-op (the window is already 8). The 0.1.56 "12 rows = -1.4 %" line therefore is not a
DFlash2 result and should not be cited as one.

What the copy cell already shows is the important part: at the 8-row cap the drafter is in its
near-perfect regime, **97.5 % acceptance and 123.9 tok/s warm** - about +12 % over the 85.3 %/111
chat cell - with the copied text byte-identical between reps (sha `b112adf5...`). There is no
acceptance left to buy at this window width: 99 % would be ~+2 % over copy and ~+14 % over chat,
which is the round-12 bound restated.

**Verdict: no config change, production not touched, the lookup-window family is closed for this
lane** - the 8-row cap is structural. The refit side is scoped in
`dflash2-refit-scope.md`. Artifacts: `/data/ab53-window.log`, `/data/ab53-{base,lk12,lk9}.log`,
`/data/ab53-metrics-*.json`, harness `/data/ab53.py` + `/data/ab53-base.json`.

### Round 17b: the draft-skip knob (2026-11-23, same day)

The last in-cap knob: `STRATA_DF2_LOOKUP_SKIP=N` (`spec/window_rule.hpp`,
`skip_draft_for_lookup`) skips the DFlash2 draft round when the suffix finds a match of at least
N tokens and lets the draft policy take the lookup window directly; the draft is deferred to the
next round, not lost. Same harness and cells, arms base2 / skip8 (`=8`),
counterbalanced base, skip, skip, base, `STRATA_DRAFT_LOG=1` in both arms. Window
09:43:00-09:49:08, production restored and healthy at 09:49:57.

| arm | copy cold / warm tok/s | edit cold / warm |
|---|---|---|
| base2 (2 runs) | 111.2 / 123.6, 111.1 / 123.2 | 113.7 / 118.6, 110.4 / 117.0 |
| skip8 (2 runs) | 113.1 / 125.0, 113.0 / 126.0 | 111.2 / 119.0, 113.5 / 120.1 |

Means: copy cold 111.15 -> 113.05 (**+1.7 %**), warm 123.4 -> 125.5 (**+1.7 %**), while
the copy text stays byte-identical (sha `b112adf5...`) and the two base arms stay inside
0.3 %. The draft log shows the mechanism and the size: the same 76-77 rounds for 512 tokens,
decode_ms 4,603/4,608 -> 4,527/4,531 cold and 4,141/4,156 -> 4,096/4,065 warm, i.e. **~1 ms
per round** - the DFlash2 draft call. Edit is inconclusive inside that cell's 7 % spread
(means +0.3 % cold, +1.5 % warm); prose is inert here (no 8+ token match fires) and its answer
length drifts.

**Verdict: real but small, greedy-only, and below the +4 % gate - not deployed.** The arms ran
greedy (temperature 0) like every campaign cell, while the lane serves the model card's sampling
by default (0.7 / 0.8 / 20 / presence 1.5): there the verifier samples and a deterministic lookup
proposal is accepted with its target probability rather than min(1, p/q), so the lookup's
acceptance is not the greedy number and the skip's sign was unmeasured then (round 17c measured
it: the same sign and size). A sampled copy/edit A/B is
therefore the precondition for carrying it. It stays a cheap passenger - env-only, copy/edit text
unchanged, and inert on short-match text - but not worth a generation on this evidence alone. Artifacts: `/data/ab53-skip.log`, `/data/ab53-{base2,skip8a,skip8b,base2b}.log`.

### Round 17c: the sampled A/B (2026-11-23, same day)

The gap round 17b left: its arms ran greedy, while the lane serves the model card's sampling by
default. Same harness with `AB_SAMPLE=1`, which sends exactly that set (0.7 / 0.8 / 20 /
presence 1.5), cells copy+edit (fixed counts), 3 reps per cell per engine, arms base3 / skip3
counterbalanced base, skip, skip, base. Window 10:03:39-10:09:37, production restored by the
trap and healthy at 10:10:44.

| arm | copy cold / warm tok/s | edit tok/s (6 runs) |
|---|---|---|
| base3 (6 copy runs) | 111.5, 110.9 / 124.3, 123.5, 123.2, 122.2 | 111.5, 105.7, 120.8, 103.3, 103.2, 117.3 |
| skip3 (6 copy runs) | 112.9, 113.0 / 125.2, 126.2, 124.9, 125.9 | 106.2, 119.9, 108.8, 118.3, 117.5, 99.6 |

Means: copy cold 111.2 -> 112.95 (**+1.6 %**), warm 123.3 -> 125.55 (**+1.8 %**), acceptance
unchanged on the cold reps (436/447 both arms) and the copy text still byte-identical (sha
`b112adf5...`). The sampled copy cell is effectively greedy because `top_p 0.8` cuts the nucleus
to the copied token, so it exercises the knob under the served request parameters without
sampling drift. Edit is genuinely sampled (six different answers per arm) and its 99-121 tok/s
spread leaves the mean (110.3 vs 111.7) uninformative - no harm signal, no evidence either.

**Verdict: the sign and size hold under the served sampling (+1.6-1.8 %, matching greedy's
+1.7 %), so the knob is validated for this lane.** Owner-approved on 2026-11-23 under the
cumulative-wins policy (env-only, output-preserving arms no longer wait for +4 %), and live since
generation 121 (10:45): the engine's process env carries `STRATA_DF2_LOOKUP_SKIP=8` (config JSON
`89ic7xvn...`). The first attempt was blocked by an unrelated fixed-output hash mismatch in the
turing-unlock firmware's NVIDIA 610.43.03 package; dropping that module (same generation,
`hosts/tiberius.nix`) unblocked the build.
Artifacts: `/data/ab53-sample.log`, `/data/ab53-{base3,skip3a,skip3b,base3b}.log`.

## Source-level patch roadmap

Each item has a mechanism, the file/function the reports point at, a risk, and one validation probe.
Likely files: `pkgs/strata-sm75/tiberius.patch` + `default.nix` for items 1/2/5; `serve/server.py`
for item 6; `profiles/nixos/strata.nix` only for an adopted fix/flag, by the deploy task.

1. **Transactional park - landed and deployed (generation 101, 2026-11-04).** A refused park must
   not evict parked conversations or consume the K/V donor: `park_source()` took the donor via
   `take_reuse_for` and ran the RAM-admission eviction loop *before* the final `admit()`, and a
   post-capture floor refusal discarded the captured image. Fix: pre-check feasibility against
   available + `ConversationCache::evictable_bytes()` and skip early with a distinct line, giving
   the donor back via `ConversationCache::give_reuse()`; the success path is unchanged. Pointers:
   `src/program/generate.cpp` `park_source()` (~11590-11770 in 0.2.10), `conversation_cache.hpp`,
   test seam `src/core/conversation_cache_test.cpp`; marker greps in `pkgs/strata-sm75/default.nix`.
   Probe (isolated port 8099, forced refusal under a measured mlock hog): pre-fix "evicted 2, 0
   still parked" with the next prompt re-reading 1,745 tokens from zero; patched "nothing evicted,
   2 still parked" with the parked copy restored (1,738 tokens reused in 69.5 ms); normal
   park/restore unchanged and all six answer shas identical. Deployed as generation 101
   (`/nix/store/07pr3sndmbszvsyq8jayd334ak0nwf59-nixos-system-tiberius-...`), engine
   `/nix/store/3qla1qfa09rsf6rqmcnnndk04hrqvb0y-strata-engine-0.1.56`; the 7,859-slot / elastic-K/V
   / DFlash2 / 5.52 GiB DAX-window start is unchanged.
2. **DAX rotation pipelining - measured and REJECTED 2026-11-04; timing seam kept and deployed.**
   The instrumentation answered the mechanism question: the per-window fence wait is ~0 ms, but
   `cudaHostUnregister` while the copy engine is active costs 60-260 ms/rotation (21.5 ms after a
   drain). A two-window pipelined rotation (run cap = 6 GiB budget / 2, two resident windows)
   doubles the rotation count 9 -> 19 per pack pass and measures +1.66% / +4.13% read on
   4,260/8,276-token prompts and -5.43% on 26,142, with a deterministic P27 8-token answer-sha
   drift (the frozen two-window state changes decode PCIe grouping); zero registration refusals,
   and the same-binary `STRATA_DAX_PIPE=0` control isolates the pipeline from the binary. Reopening
   this family needs a mechanism that does not unregister while copies are in flight (retention
   instead of rotation, or a ring budget below the 7 GiB process cap) - the drain is already free.
   Pointers: `pkgs/strata-sm75/tiberius.patch` (`prepare_layer` ~528-590, `dax_register[_run]`
   ~440-520; overlap rules ~125-200). The log-only `STRATA_DAX_TIMING` seam (patch sha256
   `cd67094e...`) is kept and deployed in generation 102 for any future attempt; probe evidence:
   `/data/dax-ab/` and `/tmp/strata-tune/dax-ab/`.
3. **Streamed session RESTORE - landed and deployed (generation 103, 2026-11-04).** Two passes over
   the same fd: pass 1 validates the v1 header/trailer/payload hash with metadata only; pass 2
   re-parses and streams each K/V section into the session pools through a 16 MiB pinned staging
   block, with the RAM gate moved after pass 1 to the exact metadata-derived peak (~270 MiB at
   250k; old path 3,727 MiB). No file-format change; corrupt/truncated files are refused in pass 1
   before any device write, and a failure after the first write keeps the FATAL contract. The same
   patch fixes a pre-existing bug the first window exposed: SAVE unconditionally passed
   `mtp.kv_state()`, which is an empty QsaState on the deployed DFlash2-alone lane (no `--mtp`), so
   every SAVE there failed with "invalid K/V extent" - disk sessions had never worked on this lane
   (the 2026-11-01 SAVE/RESTORE numbers in the round-1 plan were measured on the MTP lane). SAVE
   and RESTORE now make the draft layer optional (`layers + (use_mtp ? 1 : 0)`; MTP-lane files stay
   byte-identical, DFlash2-lane files are layers-only, a mismatched file is refused), and RESTORE
   invalidates the DFlash2 drafter before the session goes live. Measured: 240k restore 5,240 ms
   with VmHWM +259 MiB and an identical greedy continuation sha; 50k restore 1,409 ms, sha equal;
   old-writer MTP file restores; cross-lane file refused; corrupt/truncated/header all SERR
   invalid with the same pid and a working next request; RESTORE->GEN->SAVE->RESTORE and the
   park regression clean; `STRATA_TEST_COPY_FAIL_AT=1` SERR io (engine alive) and `=2` FATAL
   (engine restarts on the next request, no partial answer). Build
   `/nix/store/gv3vlx7ah...-strata-engine-0.1.56`; two independent reviews (one critical
   metadata-validation bug and one park-validator regression were caught and fixed before the
   window). Accepted follow-ups on the next regeneration: restore the four "payload ends early"
   over-read guards and `conversation_file.cpp`'s final newline. Design/results:
   `/tmp/strata-tune/stream-restore-design.md`, `stream-restore-results.md`.
4. **pmem park spill - implemented, validated and ENABLED in generation 107 (2026-11-05).** Implemented as patch `a833153c` (+~775 lines) with the round-8 checkpoint match (patch `1f2393f2`): the
   *adaptive hybrid* - keep the RAM park path byte-identical, and when the transactional pre-check
   (or the parked-cache budget) refuses, write the park as a v1 session file on `/optane`
   (XFS dax=always) with the existing SAVE writer (live + deepest/pinned checkpoint, K/V streamed
   from the pools), insert a metadata-only file-tier entry (~2-3 MB), and restore it with the
   generation-103 streamed RESTORE. That turns the size-proportional gate (4,276 MiB at 250k) into
   a constant capture (~371 MiB) plus the floor, so the logged refusals become file parks and the
   next turn reuses instead of re-reading (164 s at 250k). New settings: a park directory, a size
   cap (~12 GiB), more slots and a free-space reserve; never evict a RAM entry for a file park;
   `give_reuse` the donor. Pure mmap-arena (option a) was rejected: it moves only the K/V and the
   live+checkpoint state still refuses long chains, for ~1.2-1.6k lines and no persistence. Estimated
   ~800-950 engine lines + ~200 test lines over 6 files, 10-20 min build, 15-20 min GPU window.
   Risks: Optane thermal headroom (media 77 C, controller 83 C vs 85 C critical), write volume from
   ~3.6 GB files, and the ~7 GiB registered-memory cap (~6.3 GiB already used by the pack window)
   ruling out cudaHostRegister for park pages - stage through the 16 MiB block. Probe: forced-pressure
   two-conversation isolation, 100k/250k park+restore where today it refuses, VmHWM <= +400 MiB,
   service-restart persistence, greedy sha parity, normal-park regression, corrupt/foreign refusal.
   Design: `/tmp/strata-tune/pmem-park-design.md`. Validation (two isolated windows): file park
   write 4.5 s / ~3.6 GB at 250k with tier peak 10.16 GiB, streamed restore from a pmem park 5.17 s
   with checkpoint reuse, corrupt-park pass-1 refusal + identical reread, RAM path unchanged. The
   ordinary-turn "park -> next turn restores" match was NOT taken (the file keeps only the deepest
   prefill-chunk checkpoint, which did not match the next prompt). Fixed in round 8: the park saves
   the deepest chain checkpoint >=1024 tokens below the live state (the stable prefix the engine's
   own continuation reused, 225,280 at 250k), matches only the saved/live states, and prefers a file
   over a full reread; validated and enabled in generation 107 with 6 GiB / 4 slots / 4096 MiB
   reserve + stale-file cleanup. Residual: 4.5 s blocking capture, ~3.6 GB per 250k park, Optane
   thermals; 6 GiB holds one long park (8 GiB for two).
5. **CUDA port of upstream #4677 - LANDED in generation 108 (2026-11-05, patch 6f44477).** `stop_bound` and both call sites sit inside
   `#if defined(STRATA_USE_HIP)`, so a CUDA verify window cannot commit-bound at an EOS inside it;
   removing the guard is ~20 lines plus a correctness run. Pointers: `generate.cpp:17403-17410`,
   `:17966-17972`; `include/strata/core/serve_stop_bound.hpp`. Risk: changes stop handling (not
   speed). Probe: park/restore and stop handling, plus answer sha on the normal cells.
6. **Per-window telemetry counters - LANDED in generation 108 (2026-11-05, patch 6f44477).** Expose rotations/request,
   prompt-path borrow bytes, tokens/verify-window, acceptance by window size and prefill phase times
   as counters on `/metrics/prometheus`; today they are log-scraped and there are no histograms.
   Pointers: `serve/server.py` `Latencies` (~4564), the `?requests=all` path (~7535);
   `STRATA_PREFILL_TIMING` is log-only. Risk: counters only, no answer change; keep the endpoint
   public-safe (no request payloads). Probe: counters present, one campaign run reconciles with
   log-derived numbers, no measurable perf cost.

## Sequencing

Campaign block A+B (task-4) first with the decision rules; then the park patch build/probe
(task-6 -> task-7) in the GPU-free window, go/no-go to the Lead; then the prompt-path patch item and
the DAX rotation timing probe; the C9 harness upgrade (drafter bench + eval320) before any 5% decode
claim. Deploy only what survives, each adopted flag carrying its measurement link into the module
comment - the Lead owns the switch.

## Measurement caveats

- **eval80 is a guardrail, not a ranker.** 80 exact-answer items: one-pass binomial sigma ~3.8-4.0
  tasks, between-arm sigma_diff ~5.4 (the docs' "1 sigma about 5.4"), 95% CI on a difference
  ~+/-10.7 tasks; only >=10-task (>=12%) moves are detectable. Reject an arm at >8 tasks worse; rank
  nothing with it. The C9 upgrade: 320-400 held-out items, McNemar analysis, fixed-corpus PPL gate.
- `evalrun.py` must send `temperature: 0`: on gen 100 it sends none, so the card's stochastic
  sampling would leak into "greedy" comparisons.
- **3 counterbalanced runs resolve ~1.5% on read and ~2-3% on decode** (ab26/ab31 spreads); a 2-run
  screen cannot distinguish <4%, and the 8-gen P27 decode cell has 11.5% spread - never decide on it.
- Report **mean with [min-max]**, not medians (`/data/ab10-parse.py` uses `statistics.mean`).
- **Provenance**: `/data` drivers and `base-*.json` disagree with their own engine logs (an
  MTP-named script whose log shows DFlash2); the engine start line is authoritative. Snapshot base
  config + driver + sha256 into `/data/campaigns/<date>/` before each campaign.
- Answer sha equality is not a bitwise test for drafter arms; use the engine's
  `--spec-follow`/`--window-hashes` bench on one continuation (C9) before claiming parity. Live
  `/metrics` `history` is 60 s in RAM and un-scraped; drift detection needs a 15 s scraper + item 6.

## Acceptance criteria

- Every adopted arm meets its decision rule with 3 counterbalanced runs, per-run values and
  [min-max]; answer sha for all cells; answer-changing arms also pass eval80 not >8 worse, needle
  3/3 and a clean repetition probe.
- Env-only arms that cannot change the affected cells' text (byte-identical text checked) and
  whose mechanism is measured may be adopted on a reproducible positive effect - the same sign in
  2+ paired runs with the base spread quoted - even below the +4 % decode bar. The bar stays for
  answer-changing or risk-adding arms. Owner call 2026-11-23: small wins compound (the British
  cycling argument), so the +4 % gate is a default, not a veto. `STRATA_DF2_LOOKUP_SKIP=8` is the
  first case (rounds 17b/17c).
- The prompt-path campaign reports the fitted intercept and marginal rate before/after
  (`read_ms = a + b x fresh_tokens`); a flag removing <3 s is not adopted, and engine-internal phase
  numbers become the patch item.
- The park patch has pre/post probe evidence (a refused park leaves parked conversations intact),
  passes a normal-park regression and leaves sha unchanged; no deploy until task-7's go/no-go.
- Provenance under `/data/campaigns/2026-11-04/` for every run, including engine start lines;
  results recorded in `docs/VALIDATION.md` / `strata-pack-restore.md` with evidence pointers.
- `scripts/validate` and the host eval pass; no `profiles/` or `pkgs/` change is made by the
  campaign phase - the deploy task applies an adopted flag with this plan's evidence.

## Validation commands

```sh
scripts/validate
nix eval --raw .#nixosConfigurations.tiberius.config.system.build.toplevel.drvPath
nix build --dry-run --no-link .#nixosConfigurations.tiberius.config.system.build.toplevel
git diff --check
```

No SSH, deploy or secret decryption in validation; the patched engine build is a manual GPU-free
window on tiberius (task-7), not a CI step.

## Public boundary

Public-safe: measured numbers and public upstream flag names only. No live logs, engine-log excerpts,
`/metrics` dumps, command transcripts or private IPs are committed; evidence is cited by path
(`/persist/strata/...`, `/data/...`, `/tmp/strata-tune/...`), never pasted. No secrets or account data
are involved; deploy/SSH stays out of default validation and public CI (`docs/PUBLIC_BOUNDARY.md`).

## Deferred / closed

- **Deferred hardware**: +RDIMM DRAM (8 -> 40-48 GB), a second DCPMM for 2-way interleave, and a GPU
  (32 GB sm_120 is the only material slot win; the 22 GB 2080 Ti stays). Out of scope this round; the
  box audit has the case and the destructive-window/thermal warnings.
- **Closed by measurement (do not re-propose)**: `--vram-reserve-mib 768` (-2 hit points at the old
  geometry); `--prefill auto`/`14336` (flat); DAX window >6144 MiB (6912 saves <=1 rotation, 7168
  refused); `--prefill 28672`; `STRATA_IO_PREFETCH`/`COLD_OVERLAP` (needs a page cache DAX does not
  have); `STRATA_PREFILL_LAYER_MAJOR` (56,320-token super-chunk + 1.4 GiB vs 777 MiB free);
  `--prefill-head-alias` (needs `--mtp`); `STRATA_DMA_BATCH` (needs CUDA 13; build is 12.9);
  `STRATA_SPEC_COST`/MTP knobs (no MTP layer); `STRATA_PF_FUSED[_SM75]` (inert, no win);
  PA_V2T/SELECT_SIMT/ADAPT_NOWAIT/LAG (answers move, no win); batch/parallel/layer split/GDN tensor
  cores/YaRN 1M/`--resident-budget-gib` (not applicable); CPU governor/pool/ISA and prompt-cache
  root/tail/spread families (conclusive null for this shape); `--lookup-max-t` > 8 with DFlash2
  (`native ERR dflash2: draft rows out of range`, round 17).
- **Harness/quality (landed 2026-11-04)**: eval320 + paired McNemar + PPL + test-retest are in
  `/data/eval320/`; answer-changing arms can now be ranked (5.9% same-stack variance floor, ~2.8 pp
  detectable net edge). Still open: per-window counters on `/metrics` and tuning the telemetry
  alert thresholds against a week of the new JSONL.
- **Not carried from round 1**: the 524,288 context and 1M YaRN lane (slot cost), and the k8v4 KV
  (retested in row 5, not adopted yet).

## Progress log

- **2026-11-04, block A** (16.4 min downtime): prompt-path sweep + chunk/reserve/routed-stream arms.
  All rejected; the fixed cost is DAX pack-stream/copy wait (`wait copy` 36.9% of the GPU timeline
  at 4.2 k tokens, 3.7% at 26 k), not host setup. `--prefill 28160` + borrow kept.
- **2026-11-04, block B** (24.4 min downtime): DFlash2 window + k8v4 + sampling. spec8 -2.9%,
  lookup8 no-op, lookup12 -1.4%, k8v4 -10.7% L-live (long-context +2.6%, below gate), card0 -0.7
  tasks. Nothing adopted; config byte-identical.
- **2026-11-04, park patch**: regenerated `pkgs/strata-sm75/tiberius.patch` (third local change),
  built on tiberius (`3qla1qfa...`, 7 min), isolated probe passed (above), and deployed as
  generation 101 at 17:40; service healthy, smoke completion "Ready", engine start line carries the
  patched store path and the unchanged 7,859-slot / elastic-K/V / DFlash2 / 5.52 GiB DAX start.
- **2026-11-04, round 3 / DAX**: four-way A/B (base, two-window pipeline, same-binary PIPE=0
  control; 3+3+2 runs) in an 11.0-min window - REJECTED (+1.66%/+4.13% on 4.2k/8.3k reads,
  -5.43% on 26k, rotations 9->19, P27 sha drift); mechanism attributed by the new timing seam
  (fence ~0, unregister 60-260 ms while copies are live). Timing-only patch kept
  (`cd67094e...`) and deployed.
- **2026-11-04, round 3 / measurement**: eval320 (320 items, verified 320/320) + McNemar + PPL
  harness landed in `/data/eval320/`; baseline 58.1%/59.7%, same-stack variance floor 5.9%
  (kappa 0.877), ~2.8 pp net-edge detectability; logprob/PPL gate usable with common-prefix pairing.
- **2026-11-04, round 3 / telemetry + hygiene**: `profiles/nixos/strata-telemetry.nix` 15 s
  scraper/timer deployed; pre-existing statix warnings merged; `scripts/validate` green.
  Generation 102 (system `ppprl8ix...`, engine `ixssrl2q...`) deployed at 18:47 and verified
  (health, warm smoke, park+timing markers, telemetry timer active, unchanged 7,859-slot start).
- **2026-11-04, round 4 / flags**: two trap windows (13.2 + 22.3 min) and 11 isolated runs.
  prior135 lost L-live -6.29% / P2 -7.54% (P27d +2.23%), skip8 -4.6..-10.7% and skip9
  -4.7..-13.5% across the cells; pre-registered rules failed at the screen, so the route-prior
  family closed at 1.2 and tail-skip at 7 with no eval320 window spent. Cache probe: deployed
  settings had 0 pressure refusals and 5/5 turn-2 prefixes in the isolated window; prompt-cache 3
  and cache1024 did not beat it -> settings stay. Round 4 adopted nothing, config unchanged.
- **2026-11-04, round 4 / design**: streamed session RESTORE design completed - two-pass, no
  format change, 250k peak host RAM 3,727 MiB -> ~260 MB, ~700-750 lines over 5 files; adjacent
  DFlash2 drafter-reset bug on restore found and separable. Next patch round.
- **2026-11-04, round 5 / streamed RESTORE**: implemented the two-pass streamed restore (~270 MiB
  peak at 250k vs 3,727 MiB) plus `df2.reset()` after restore and draft-optional SAVE/RESTORE
  (fixing a pre-existing bug: SAVE had never worked on the deployed DFlash2-alone lane). Two
  independent reviews (critical pass-1 validation bug; park-validator regression) fixed before the
  successful window. Validated: 240k restore 5.24 s / +259 MiB / identical sha; 50k, old-writer
  MTP, cross-lane refusal, corrupt/truncated/header, round-trip, park regression, copy-failure
  seams all pass. Deployed as generation 103 at 21:44; service healthy, smoke answered, telemetry
  timer active. Accepted follow-ups: over-read guards + final newline next regeneration.
- **2026-11-05, round 6 / hygiene**: regenerated the patch to restore the four over-read guards +
  final newline (one-file delta), unit tests green, rebuilt (`sz2dwc0k...`), 2m21s isolated smoke
  (50k restore sha equal, corrupt/truncated/header SERR invalid same-pid, park spot check clean),
  deployed as generation 104. Row 9 closed without a window; Turing-unlock assessed (do not attempt
  on this hardware); pmem-park design completed for the next round.
- **2026-11-05, round 7 / Turing unlock + pmem hybrid**: tested nlzy/turing-unlock in a one-shot
  generation (TU102 FEAT UNLOCKED, driver 595 healthy, no Xid); controlled A/B measured prefill read
  -6.2 / -2.6 / -1.0 % at 26,134 / 8,268 / 4,252 tokens at 200 W and -5.7 / -2.0 / -1.1 % at 280 W,
  decode flat, answers identical; adopted via `hardware.turingUnlock` (boot initrd module, firmware
  generated at build time, not committed) and deployed in generation 106. Implemented the pmem
  park-spill hybrid (patch `a833153c`) and deployed it dormant after two validation windows: file
  park write 4.5 s/3.6 GB, streamed restore 5.17 s, corrupt-refusal path and RAM regression pass;
  ordinary-turn restore match is the follow-up before enabling.
- **2026-11-05, round 8 / pmem checkpoint match + Unsloth**: two windows diagnosed the junction
  re-tokenization (saved checkpoints 239,184/239,190 are not prefixes after appending a turn) and
  fixed it (deepest chain checkpoint >=1024 tokens below live; whole chain as metadata; prefer file
  over reread; STRATA_PARK_DEBUG). Validated: ordinary-turn 250k park -> next turn restored 225,280
  tokens in 5.15 s (19.4 s incl. 13,917 re-read) vs 152.6 s reread, identical sha; corrupt refusal
  and RAM regression clean. Enabled with 6 GiB/4 slots/4096 MiB + stale-*.park cleanup, deployed as
  generation 107 (patch 1f2393f2, engine gci3izr...). Unsloth Dynamic V3.1 assessed
  (`unsloth-dynamic-v31-assessment.md`): not adoptable as-is (GGUF/K-quant mismatch, ~82 GB lane),
  UD-IQ3_XXS experiment recorded as task-24.
- **2026-11-05, round 8b / CUDA #4677 + counters**: ported the EOS stop bound to CUDA (A/B answers
  identical with the bound on/off) and added the per-request WSTAT telemetry (nine strata:* families
  + verify-window histogram + prefill phases; JSON and legacy prometheus endpoints). Fixed the
  stash-wiped-by-DONE and legacy-endpoint bugs and made the rotations counter cumulative; final
  window all families present/monotonic and rotations reconciled with the engine log. Deployed as
  generation 108 (engine gwhnf6m..., patch 6f44477...).
- **2026-11-05, round 9 / Unsloth switch**: built both UD packs (IQ3_XXS 46.84 GiB, IQ2_XS 39.38
  GiB) from the Unsloth V3.1 GGUFs and ran 3-pass eval320 + a 4-cell speed probe on each. Arm IQ3_XXS:
  +1.4 pp quality (within floor), neutral speed, 2 DAX registration failures/pass. Arm IQ2_XS:
  quality parity (-0.2 pp), prefill -14.8 % P1 / -11.5 % P8K / -16.3 % L-live read, decode +4.1 %,
  no DAX failures, 8,898 cache slots; DFlash2 acceptance 85 % vs 98 %. Adopted IQ2_XS and deployed
  as generation 109; lane config gained midShards/pleShard/pleFile for 3-shard models. Old source
  GGUFs/PLE deleted (redownloadable); coder lane PLE currently missing (follow-up).
- **2026-11-05, round 10 follow-ups**: DFlash2 spec/draft-conf sweep on the UD pack (8 variants):
  acceptance loss is spec-window-driven (spec 4 -> 91.6 % acceptance, -1.2 % decode; confidence
  knob has no effect; identical L-live text across variants) - no knob change adopted. Coder lane
  marked unavailable via a module assertion with its restore procedure; rollback source URLs/LFS
  hashes and the IQ3_S pack rebuild steps recorded.
- **2026-11-05, round 11 / chunk screen**: `--prefill 56320` is clamped by the engine to 28160
  ("buffers fit in every expert cache"), so the 38k real-traffic cell cannot be made one-chunk with
  this knob; 38k/26k/4k read deltas were noise. Kept 28160. Park spot check with the new pack
  passed (reused>0, no invalid snapshots); noted that a restored 3,477-token conversation's
  continuation can differ from the live one (checkpoint-continuation state effect, same class as
  the eval pass-state flips). No deploy.
- **2026-11-05, round 12 / DFlash2 refit bound**: drafting-off (fallback-only) L-live decode 62.3
  vs 113.85 tok/s with DFlash2 = the drafter already buys 1.83x; perfect-acceptance ceiling
  ~+15 % decode (mean) and no prefill gain, so no refit. See round-12 section.
- **2026-11-23, round 17 / copy-heavy lookup screen (0.1.63)**: the last acceptance lever closed. `--lookup-max-t` 9/12 with DFlash2 starts and captures the wide window, but the first copy request ends the draft (`native ERR dflash2: draft rows out of range`, HTTP 400): the 8-row block cannot feed a longer window, so 9+ rows are unsupported, not slow. The copy cell at the 8-row cap already measures 97.5 % acceptance (436/447) and 123.9 tok/s warm against 85.3 %/111 on chat - the near-perfect regime, worth ~+12 %, i.e. the round-12 +15 % bound as measured. No deploy. Refit scoping in `dflash2-refit-scope.md`: 600 M drafter, 51.2 KB/token tap capture through `STRATA_TAP_FILE`, 1 M tokens = 51 GB / 2.5 h, upstream ~800 K samples; a real 10-50 M-token attempt is 3-6 weeks for ~+3-8 pp, so not recommended now.
- **2026-11-23, round 17b / draft-skip knob**: `STRATA_DF2_LOOKUP_SKIP=8` (skip the DFlash2 draft when a suffix match of 8+ tokens exists, take the lookup window directly) is real but small: copy 111.15 -> 113.05 cold / 123.4 -> 125.5 warm (+1.7 % both), same 76-77 rounds and ~1 ms/round less decode (4,603 -> 4,527 ms cold), copy text byte-identical; edit inconclusive in a 7 % spread; prose inert by design. Below the +4 % gate, not deployed; safe to carry in the next generation if one happens for another reason. Artifacts `/data/ab53-skip.log`.
- **2026-11-23, round 17c / sampled A/B**: the skip knob under the served card sampling (0.7 / 0.8 / 20 / presence 1.5), copy+edit, 3 reps x 2 engines per arm. Copy cold 111.2 -> 112.95, warm 123.3 -> 125.55 (+1.6 / +1.8 %), acceptance identical (436/447 cold) and the copy text byte-identical; the sampled copy cell is effectively greedy under top_p 0.8. Edit sampled and noisy (99-121 tok/s both arms), no harm signal. Owner-approved 2026-11-23 under the cumulative-wins policy and live since generation 121 (10:45); the first attempt was blocked by the turing-unlock NVIDIA 610.43.03 URL rot, and dropping that module unblocked the build. Artifacts `/data/ab53-sample.log`.
- Evidence (local, not committed): `/data/campaign-2026-11-04/`, `/data/dax-ab/`,
  `/data/eval320/`, `/data/round4/`, `/tmp/strata-tune/` (incl. `stream-restore-design.md`,
  `stream-restore-results.md`, `hygiene-round6.md`, `pmem-park-design.md`,
  `parkspill-round7.md`, `turing-bench-results.md`; `/data/round7/`).
