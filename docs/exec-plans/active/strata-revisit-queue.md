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

## Tested 2026-11-23, second window (15:36-16:15, 5 reps, control p1 63.6 / llive 70.3)

| arm | knob | result |
|---|---|---|
| `df2_gemm_off` | `STRATA_DF2_GEMM=0` | -0.4 % p1 (0/5) / -0.1 % llive -> the default layout (1) is better; keep it |
| `suffix_draft2` | `--suffix-draft 2` | -0.1 % / +0.0 %, read -1.8/-1.0 % -> keep 3 |
| `suffix_draft4` | `--suffix-draft 4` | -0.1 % p1 / +0.5 % llive (3/5), answers differ -> no win; keep 3 |
| `df2_prio_off` | `STRATA_DF2_PRIO=0` | -0.4 % p1 (1/5) / -0.2 % llive -> keep the high-priority draft stream |
| `aux_cpus` | `STRATA_AUX_CPUS=auto` | decode ~0, but read **-4.9 % / -3.4 %** -> the aux-thread move does not pay on this box |

None adopted; the defaults stay. Evidence `/data/knob-screen-20261123-1545/`.

## Tested 2026-11-23, third window (16:28-16:52)

| arm | knob | result |
|---|---|---|
| `park_ram` | `--prompt-cache 3` + `STRATA_DF2_LOG_MIB=64` | **inconclusive in isolation**: control parked too at 48,638 tokens (the repeat reused 48,633 tokens in 0.44-0.55 s against 31 s for the read), because the isolated engine has ~4 GiB free where production runs at ~1.1 GiB. The live park refusal needs the production RAM pressure; the RAM knobs are **not adopted** on this evidence (the tier works, the isolation cannot reproduce the failure). |
| `tail_skip8` | `STRATA_ROUTE_TAIL_SKIP=8` | quality gate **passes** (eval320 196/320 vs 194 for 7, +2 items, inside noise), but decode is **-2.7 % p1 / -3.0 % llive** (1/5 up each) -> not adopted. Skipping rank 8 is slower, not faster, on this stack. |

Evidence `/data/knob-screen-20261123-park/`, `-tailskip-eval/`, `-tailskip/`.

## Tested 2026-11-23, fourth window (the rest of the queue)

Quality first (isolated engine, eval320 + the repo's fixed-corpus PPL, temperature 0):

| arm | eval320 | PPL (repeat spread) |
|---|---|---|
| `kv_k8v4` | 191/320 (-3 vs the 194 control) | 1.178 (0.007 nats) |
| `prior_1_15` | 196/320 (+2) | 1.197 (0.012 nats) |
| `prior_1_25` | 194/320 (0) | 1.171 (0.022 nats) |

All three pass the task gate; the PPL arm-to-arm deltas sit inside the probe's own repeat
spreads (0.007-0.022 nats), so none shows a measurable likelihood cost. (The plan originally
asked for KL/top-1; the repo's continuous gate is the fixed-corpus PPL probe built 2026-11-04,
and it was used instead.)

Throughput, long cells (5 reps; llive 26,134 / xlive 38,000):

| arm | llive | xlive | verdict |
|---|---|---|---|
| `kv_k8v4` | **+6.1 %** (5/5, answers identical), **read -10.0 %** | **-9.7 %** (0/5, answers differ), read -9.6 % | reject: the win does not survive 38k and the prompt read pays 10 % |
| `prior_1_15` | -5.2 % (0/5) | -3.0 % (0/5) | reject |

Low-value sweep (3 reps, p1; any sign to be confirmed at 5):

| arm | knob | result |
|---|---|---|
| `kv_grow_step` | `STRATA_KV_GROW_STEP=16384` | -0.6 % (0/3) |
| `prefill_equal` | `STRATA_PREFILL_EQUAL=1` | -0.2 % (0/3) |
| `pool_spin_off` | `STRATA_POOL_SPIN_US=0` | -3.1 % (0/3), read -3.2 % |
| `lookahead_6` | `STRATA_LOOKAHEAD_K=6` | +0.2 % (2/3), read -4.3 % |
| `cpu_ymm` | `STRATA_CPU_YMM=1` | +0.6 % (3/3) at 3 reps, but **+0.1 % (3/5)** at 5 reps -> not reproducible; no adoption |

**The queue is empty.** Beyond the pin (generation 123) and spill-persist (generation 124), no
arm is deployed; the engine's defaults stay. The one-arm-at-a-time production windows all
restored the unit (health 200 after each).

## Follow-on: the `#4870` surface (2026-11-23, after the pin attribution)

The pin's decode gain turned out to be the mid-coverage adaptive rule, which made the rule's own
parameters the highest-value knob left. Swept in two isolated windows (5 paired reps, llive):
`--adapt-every 1` (rule supplies 192/0.92) is **+11.0 %** (5/5, answers identical, read +0.4 %);
`--adapt-decay 0.95` (+2.4 % alone) and fewer swaps are worse on top; swaps 288 and
3/160/0.88 regress. Quality: eval320 195/320 (+1). **Adopted: generation 125**
(`--adapt-every 1`). Any future sweep starts from 1/192/0.92.

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
