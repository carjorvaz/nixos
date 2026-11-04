# strata tuning round 2: the prompt path, the verify window, and park

Status: **active, rounds 2-5 - campaign, park fix, measurement/telemetry, flag cleanup and the
streamed session RESTORE round done 2026-11-04** (generation 103). Round 4 adopted nothing (run
config unchanged); round 5 landed the streamed RESTORE + draft-optional SAVE/RESTORE + DFlash2
drafter reset and found/fixed a pre-existing SAVE bug on the deployed lane. Open: experiment row 9
(reserve geometry), patch roadmap items 4-5 (pmem spill deferred, CUDA #4677), per-window counters,
and the two accepted NITs from the round-5 patch (over-read guards + final newline to restore on
the next regeneration). DAX rotation pipelining was measured and rejected, with its log-only
timing seam kept.
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
- No engine pin bump (`ffa80d73` is v0.2.10 and upstream `main` HEAD - nothing to bump).  The
  campaigns run on the isolated port-8099 engine; the Lead deploys only what passes its rule, and
  every deploy is recorded in the progress log below.

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
| 3 | DFlash2 window axis (lookup) | `--lookup-max-t 8`, then `12` (`user_args`), `--draft-conf 0.8`; default is **0** under DFlash2 (`lookup_default.hpp:23-30`), so no lookup windows run today; explicit N raises `--spec` to min(N,16), spec_cap 16 (9-16-row windows = two groups of 8) | P1/P2/L-live (structured/code prompt >=600 tok, `ignore_eos`, max 768; base acceptance >=85%) | 3+3; finalist 5-6 | +3-10% decode on rewrite/edit-heavy text, ~1% on prose; 26k smaller | answer-drift (wider windows change sampling acceptance; greedy sequence-parity gate) | adopt if L-live decode +>=4% in >=2/3 runs, reads within +/-1.5%, eval80 not >8 tasks worse | measured 2026-11-04: `--lookup-max-t 8` is a no-op (verify window stays 8), `12` is -1.4% L-live decode; default 0 kept |
| 4 | spec / draft-cap / conf | `--spec 4`, `--spec 8`, `--draft-cap 8`, then `--draft-conf 0.7` and `0.9` at the best width. Serve injects `--spec 6 --draft-conf 0.8` and strips the config `--spec`, so overrides go in `user_args` | P1/P2/L-live | 3; finalists 5-6 | 0-4% decode (window width on a GPU-bound loop); conf 0.7/0.9 likely +/-2% | answer-drift (sampling; greedy sha gate) | spec/cap: same rule as row 3; keep conf 0.8 unless 0.7/0.9 show >=4% decode with sha parity | measured 2026-11-04: spec8 -2.9% L-live decode (more tok/window but slower windows), answers drift on P2/P27; `--spec 6 --draft-conf 0.8` kept; conf 0.5/0.65 closed 2026-11-04 - underpowered (base spread 6.4%), answers changed, 0.8 stays (`/data/ab38-*`) |
| 5 | k8v4 long-context | `--kv int8` (deployed) vs `--kv k8v4` | P1/P2/P27 + 26k/38k decode | 3+3 | +0-8% decode at 22-38k; int8 1,056 vs k8v4 816 B/cell (-23% KV bytes) and more slots; prior 0.1.49.2 screen was +6% on one short cell, 0.1.52/router within noise | answer-drift (V becomes rotated Q4_0; KL/top-1 gate + eval80 + needle 3/3) | adopt only if decode +>=2% on >=2 cells or hit +>=1 pt, eval80 not >8 worse; else keep int8 | measured 2026-11-04: L-live -10.7% decode, P27 read +10.5%, long-context +2.6% (below the 3% gate); int8 kept |
| 6 | tail-skip | `STRATA_ROUTE_TAIL_SKIP=8`, then `9` (deployed 7; 96.6% of missed entries are already skipped at rank 7) | P1/P2/P27 | 2-3 bracketed, promote to 3+ if >=2% | 0-3% decode | answer-drift (KL rises from the adopted 0.0058 baseline; acceptance can fall at high cache %) | adopt only if decode >=2% on >=2 cells with eval80 not >8 worse and needle 3/3 | measured 2026-11-04: skip8 -5.3/-4.6/-10.7/-7.3% and skip9 -4.9/-10.4/-13.5/-4.7% on P1/P2/L-live/P27d; 0/3 decision cells >=+2%; **closed, 7 stays** |
| 7 | route-prior 1.35 | 1.2 (deployed) vs 1.35 | P1/P2/P27 | 2 campaign + full quality battery (eval80 x2, 9-turn continuation x2, 27.8k needle 3/3) | between 1.2 (clean) and 1.5 (26k 77.8 vs 61.4 tok/s but degenerated on the 9-turn probe); 1.35 unmeasured | answer-drift by construction; degeneration is the failure mode | adopt only if decode +>=5% on >=2 cells AND needle 3/3, repetition clean 2/2, eval80 within 1 sigma; else close the family | measured 2026-11-04: L-live -6.29%, P2 -7.54%, P27d +2.23% (0/3 cells >=+5%); the acceptance drop on the alternate continuation (98.8 -> 84.1%) explains it; **closed, 1.2 stays** |
| 8 | conversation-cache sizing | 2048/4/min-free 384/park-gain 512 (deployed); 1024/3/384/512; 2048/4/512/512 | 2.4k isolation probe interleaved with a 19.4k foreign request (5 probes/arm) + one 20-request mixed run | 1 engine start, 5 probes | refused-park lines -50% (893 now), reuse share within 2 pts; RAM pressure is the binding term, not the flags | no answer change (cache policy only); OOM risk below the 384 MiB floor - never test lower | reduce the budget only if refusals drop >=50% with reused share within 2 pts | measured 2026-11-04 with prompt-cache 3 and cache1024: deployed 0 pressure refusals in the isolated window and 5/5 turn-2 prefixes at 98.5% reuse; the narrowed arms never beat that (promptcache3 had the only refusal); **closed, deployed settings stay** - production pressure is a RAM-capacity effect, not a cache-flag one |
| 9 | reserve geometry | auto (deployed), `--vram-reserve-mib 0`, `512` (768 was closed at ~6.2k slots: -2 hit points) | P1/P2/P27 | 2-3 | <=1%; confirm the 7,859-slot / 777 MiB-free regime has not re-opened the #2065 paging state | bitwise paths, but a slot/residency change can drift answers (ab11) - sha gate; VRAM OOM at reserve 0 | keep deployed unless >=1% on >=2 cells with vram_free >=400 MiB | not run 2026-11-04; still open |

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
4. **pmem park spill - deferred, high complexity.** Parks are RAM-only by design (404 MiB for 2.4k,
   4,276 MiB at 250k); a pmem-backed image on `/optane` (40 GB free, DAX-speed restore) would end
   RAM-gated admission and survive a restart. Complexity: snapshot format/identity, mmap lifecycle,
   partial-image validation, failure paths; overlaps the disk session format in item 3. Probe when
   reopened: four conversations parked under pressure, restore latency/bytes, answer identity.
5. **CUDA port of upstream #4677 - behaviour.** `stop_bound` and both call sites sit inside
   `#if defined(STRATA_USE_HIP)`, so a CUDA verify window cannot commit-bound at an EOS inside it;
   removing the guard is ~20 lines plus a correctness run. Pointers: `generate.cpp:17403-17410`,
   `:17966-17972`; `include/strata/core/serve_stop_bound.hpp`. Risk: changes stop handling (not
   speed). Probe: park/restore and stop handling, plus answer sha on the normal cells.
6. **Per-window telemetry counters - proposed (enables rows 1-9).** Expose rotations/request,
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
  root/tail/spread families (conclusive null for this shape).
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
- Evidence (local, not committed): `/data/campaign-2026-11-04/`, `/data/dax-ab/`,
  `/data/eval320/`, `/data/round4/`, `/tmp/strata-tune/` (incl. `stream-restore-design.md`,
  `stream-restore-results.md`).
