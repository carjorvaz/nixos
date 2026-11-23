# Strata revisit queue (2026-11-23 session sweep)

The +4 % decode adoption bar was retired on 2026-11-23 ("small wins compound"): adoption is now
reproducibility (the same sign in every paired run at 5 reps; 4/5 is a candidate). That makes a
class of past measurements actionable again — effects seen at +1-3 % inside a one-run spread,
"safe to carry" knobs never screened, and untested toggles left in the engine. This record is the
sweep of the DSH session history on `air` (181 session files, all projects) for those, with each
candidate re-checked against the 0.2.20 / engine 0.1.66 source.

Method: decompress every `~/.dsh/sessions/*/*/session.v4.jsonl.zstd`, extract every
`STRATA_*` / engine-flag mention with ±450 chars of context, keep the windows that carry a
percentage or a decision word, then cross-check the flag against `engine 0.1.66` and the plan's
"Deferred / closed" list. Snippets are past session text (not measurements made today); every
candidate below is a "re-test", not a result.

## Tested 2026-11-23 (bisect / revisit window, 5 reps, p1 4,299 / llive 26,482)

These arms were added to `tools/strata-knob-screen/`:

| arm | knob | result (5 reps, paired) |
|---|---|---|
| `df2_ctx_batch_off` | `STRATA_DF2_CTX_BATCH=0` | +0.4 % p1 (3/5), +0.1 % llive (2/5) -> neutral; not the pin's gain |
| `df2_fork_off` | `STRATA_DF2_FORK=0` | +0.2 % p1 (1/5), -0.0 % llive (2/5) -> neutral |
| `side_mixer` | `STRATA_SIDE_MIXER=2` | +0.2 % p1 (4/5, -3.0..+1.4), +0.0 % llive (4/5, -6.6..+3.0), read +1.5/+0.5 %, **answers differ** -> no win; not adopted |
| `pf_group_scratch` | `STRATA_PF_GROUP_SCRATCH=1` + `STRATA_PF_HC_REGION=1` | read +1.7/+2.9 % but decode -1.0 % p1 / **-10.7 % llive** (0/5) -> reject; the freed prompt buffers do not pay at 26k |
| `adapt_old_defaults` | `--adapt-every 4 --adapt-swaps 96 --adapt-decay 0.70` | **-5.7 % p1 / -5.9 % llive (0/5)** -> the pin's +4.7/+6.2 % IS 0.2.20's #4870 mid-coverage adaptive defaults; pinning the old values reproduces the 0.1.63 numbers |

The `#4870` rule is new after v0.2.17 (0.1.63 never logs it) and, at this lane's 36.9 %
coverage, sets adapt every 4 -> 2, swaps 96 -> 192, decay 0.70 -> 0.92. That is the pin's decode
gain; the dense INT8 TC default and the two DFlash2 toggles are neutral. Evidence:
`/data/knob-screen-20261123-1450/` and `-adapt/`; `docs/VALIDATION.md`, plan round 18.

## Queued (not yet in a window)

Ordered by expected value per window, not by size of the claim.

1. **`STRATA_DF2_GEMM=0`** — DFlash2 Q4/Q4_0 GEMM variant; the source says the two variants are
   bitwise identical (`0` = 8 rows a warp, `1` = rows by matrix size, the default). The drafter
   GEMM is ~1-2 ms/round; a decode screen with `=0` (and `STRATA_DF2_GEMM4=1`, 8 rows a warp on
   every matrix) is cheap and exact. Session: "untested here".
2. **`STRATA_DF2_PRIO=0`** — the draft stream's priority vs verify/commit (CUDA high-prio stream,
   default on). Untested A/B; a priority inversion would show as decode noise, not text.
3. **`--suffix-draft 2` / `4` / `6`** — prompt-lookup drafting off an earlier repeat; only the
   default 3 has ever run (`suffix drafts` lines in the live log: 78 windows, 246/288 accepted at
   3). The `--lookup-max-t` axis is closed (9+ rows unsupported with DFlash2), but the suffix
   width itself was never swept. CLI arm through `user_args`.
4. **`--prompt-cache 3` + `STRATA_DF2_LOG_MIB=64`** — host RAM, not speed: ~700 MiB of prompt
   checkpoints (6 x ~118 MB) and up to 256 MiB of DFlash2 lineage stash; the live log has park
   refusals at 994 MiB against a 384 MiB floor. Re-test parking admission, not tok/s. The plan's
   prompt-cache family was "conclusive null for this shape" as a *speed* knob; this is the RAM
   half that was never measured.
5. **`STRATA_AUX_CPUS=1`** — moves aux threads to CPU12; the latency doc bounds the host-thread
   wait at 5.6 % and expects ≤1-2 %, "possibly 0". Never measured. Environment-only, one window.
6. **`STRATA_ROUTE_TAIL_SKIP=8` / `9`** — 0-3 % decode, but answer-drifting: run it through the
   quality gate (eval320 not > 8 worse, needle 3/3, repetition probe), not the throughput table.
   The deployed rank is 7; only 0 vs 7 was ever tested (the 2026-11-17 quality-gate initiative is
   already examining the deployed lossy defaults).
7. **`--kv k8v4` at 22-38k** — -23 % KV bytes, +0-8 % decode expected at long context, quality
   gate needed (V becomes rotated Q4_0; not bitwise). Last screened at 0.1.49 on <= 27.5k, "within
   noise"; the 0.1.66 decode is more KV-byte-sensitive. A 26k/38k decode window + KL/top-1 gate.
8. **`STRATA_ROUTE_PRIOR=1.15` / `1.25`** — only 0 / 1.2 / 1.5 tested; routing-intervention
   strength, answer-changing → quality gate.
9. **`STRATA_KV_GROW_STEP` / `_INIT` / `_FLOOR`** — never swept for production; marked "tests" in
   the source. Low priority: a bad quantum perturbs the elastic K/V and the expert cache at once.
10. **`STRATA_PREFILL_EQUAL=1`** — equal prompt chunks (changes rounding); with the current
    `--prefill 16384` the old 28,160-token rationale no longer applies. Low.
11. **`STRATA_POOL_SPIN_US`, `STRATA_CPU_YMM`, `STRATA_LOOKAHEAD_K`** — present in the binary,
    untested. The latency doc says barriers are nil and the window sd 0.08 %, so the expected win
    is 0; keep at the bottom.

## Checked and NOT worth a window

- `STRATA_HC_UPMIX=1` — a *prefill* fusion (gr_upmix); the old one-run +1.6/+1.5/-0.4 % was a
  read-side number inside the spread, and the prompt path is already 1,380 tok/s at 26k. Would
  only be retested with a read-focused campaign.
- `--draft-cap 8` — the serve layer strips `--draft-cap`; the cap follows `--spec` (module note).
- `--spec 8` — measured -2.9 % L-live decode on this stack (module note).
- `STRATA_PF_FUSED[_SM75]` — inert on the native pack (needs the fused path's `requested()`), and
  with both flags reads were -2.5 / -0.9 / -0.3 %.
- `STRATA_ADAPT_OVERLAP_RESIDENT=1` — measured (ab11) before the resident-mode default; lost.
- `--lookup-max-t` > 8 with DFlash2 — `draft rows out of range`, closed (round 17).
- `--prefill 28160` — the 2026-11-20 switch to 16384 made this the wrong trade (KV growth).
- `STRATA_PA_V2T`, `STRATA_SELECT_SIMT`, `STRATA_ADAPT_NOWAIT`/`LAG` — answers moved, no consistent
  win; not revisitable without a quality gate and a mechanism.
- `STRATA_IO_PREFETCH*`, `STRATA_COLD_OVERLAP` — the premise (page cache) does not hold on the DAX
  pack.
