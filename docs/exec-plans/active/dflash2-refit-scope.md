# DFlash2 drafter refit for UD-IQ2_XS: scope

Status: **scoping only, 2026-11-23. Nothing ordered, nothing built, no config change.** This note
answers what a refit would take and what it could buy, so the question can be closed or opened on
numbers rather than on the intuition that 85 % acceptance ought to be 99 %.

Related: `strata-tuning-next.md` round 12 (the +15 % value bound) and round 17 (the copy-heavy
lookup screen, the cheap half of the same question); `../VALIDATION.md` §"Generation 118" (the tuned
4-bit drafter rejected).

## 1. The question, and the short answer

The deployed lane serves UD-IQ2_XS (IQ2_S experts) with the stock DFlash2 drafter and measures
**85.3 % draft acceptance** (1,827 of 2,142) at `--spec 6 --draft-conf 0.8`, 111 tok/s warm. Before
the pack switch the same drafter measured 98 % on IQ3_S. The question is whether retraining the
drafter against this pack reaches 99 %, and what that is worth.

**No to 99 %, and the prize is small even if it were free.** At a 6-token window the whole
acceptance axis is worth about **+14 % decode**: ~6.1 tokens/step today against 7.0 with a
perfect drafter; the verify work rises with the accepted rows, so the end-to-end ceiling is the
round-12 measurement's ~+15 % (mean, +25 % on its best run) with **zero prefill gain**. One point of
acceptance is worth about one percent of decode; 99 % would be worth ~14 %, and a realistic refit
lands in the low 90s.

Measured anchors, all on this lane:

| case | acceptance | decode |
|---|---|---|
| deployed chat/prose (L-live, 0.1.62) | 85.3 % | 111.0 tok/s |
| `--spec 4` (narrower window) | 91.6 % | 108.35 tok/s (−1.2 %) |
| copy cell, 8-row window, 2026-11-23 | **97.5 %** (436/447) | 111.0 tok/s (cold) / 123.9 (warm) |
| drafting off (suffix/lookup only) | — | 62.3 tok/s |
| upstream pack tuned on 4-bit targets | 78.2 % | 104.7 tok/s |

The copy row is the important one: **the near-perfect-drafter regime is already reachable on this
lane** on verbatim text (97.5 % acceptance, 123.9 tok/s warm) and it is worth ~+12 % over the 85.3 %
chat cell, not +50 %. Acceptance is not the throughput lever; the per-window verify cost is. That is also
why the 4-bit-tuned pack could be worse and why a 2-bit refit's real prize is a few percent.

A wide prompt-lookup window cannot substitute for the refit: on 0.1.63, `--lookup-max-t 9/12` ends
the DFlash2 draft path with `native ERR dflash2: draft rows out of range` (measured 2026-11-23,
`strata-tuning-next.md` round 17) — the drafter's block is 8 rows, so 8 is the window ceiling for
any DFlash2-alone lane.

## 2. What the drafter is and what "refit" means here

The drafter (incoai/Qwen3.8-Flash-Next-DFlash2, Apache-2.0; pinned in `prepare-model.py`) is a
block drafter, not a small language model:

- **5 transformer layers, hidden 2560**, 8-row block (anchor + 7 mask tokens), 7 drafts per forward
  pass; ~600 M parameters (340 MB q4_0 pack; the bf16 checkpoint is 1,206,140,008 B).
- It reads the **target's hidden states**, not just tokens: the mean of the 4 hyper-connection streams
  after target layers **5, 15, 25, 35, 45** (`5 × 2560` floats per accepted row), projected through
  `fc` (12800 → 2560). A candidate selector (top-16 per row, rank-256 bilinear) picks the path
  left to right.
- Packing: `tools/dflash2_pack.py` (Q8_0 or Q4_0 matrices; `--q4_0-selector` for the selector's
  codebooks). The deployed lane runs the stock `q4_0-selq4` pack.

A refit therefore means **distillation against this exact target**: run UD-IQ2_XS over a corpus,
capture its taps and its own continuations (the taps are the drafter's input, the target's text the
labels), and train the drafter to predict *this* 2-bit model's next tokens, then pack and evaluate
offline. Training against the unquantized HF model or
against a 4-bit quant (what upstream's tuned pack did) is the case that already failed: the tuned
pack measured 78.2 % here against the stock 85.3 %, −6 % decode.

Why the 2-bit target is harder: quantization changes the target's argmax on a small but irreducible
fraction of positions, and the drafter sees the quantized target's taps, so both its input and its
label move. That irreducible disagreement is the floor a refit can approach, not 100 %.

## 3. The data problem (the real cost)

The engine already has the capture hook: `STRATA_TAP_FILE` writes one record per verified row,
`int32 position, int32 token, then n_taps × n_embd floats` (51,208 B/token at 5 taps × 2560 × fp32),
with `STRATA_TAP_LAYERS` defaulting to `5,15,25,35,45`. This is the quantity the drafter was trained
on, so the pipeline is real, not hypothetical. What it costs:

| tokens | tap file (fp32) | capture time at 111 tok/s |
|---|---|---|
| 1 M | 51 GB | 2.5 h |
| 10 M | 512 GB | 25 h |
| 50 M | 2.5 TB | 5.2 days |
| 400 M (upstream order of magnitude) | 20 TB | 42 days |

Capture is a **verify run over chosen text**, not a corpus read: the taps exist only for rows the
verifier computed, and the research harness (`terminal/tools/dflash2/orch.py`) runs the model over
a chosen continuation with oracle drafts (`--spec 8 --spec-oracle --spec-follow`), so the corpus
and the taps line up row for row. The 1 M pilot fits on `/data` (159 GB free against 51 GB of
taps); 10 M needs a TB-class disk.

For scale: z-lab's published drafter cards describe training runs of ~800 K samples
(<https://huggingface.co/z-lab/gpt-oss-20b-DFlash>), i.e. 10^8-token order. A 10 M-token refit is
~1 % of that, and a 1 M pilot ~0.1 %. Fine-tuning a 600 M drafter can still move on 1-10 M tokens,
but there is no reason to expect the base drafter's data budget to be recovered from 1 % of it.

## 4. What has to be built

| piece | state | work |
|---|---|---|
| tap capture | **exists** (`STRATA_TAP_FILE`, research hook) | none; needs a corpus + disk |
| training loop | **does not exist**; z-lab's repo ships `model.py`/`benchmark.py` only, no trainer | 1-2 weeks: PyTorch trainer around `DFlash2DraftModel`, CE + MSE loss (the architecture's two heads), tap loader, masking schedule |
| pack conversion | **exists** (`tools/dflash2_pack.py`) | none |
| offline acceptance eval | **exists** (`terminal/tools/dflash2/{dflash2_ref.py,run_eval.py,run_all2.py}`) | wire to the new pack; a day |
| serving eval | exists (L-live/eval320 gates) | a maintenance window per candidate |

Training compute is not the bottleneck: 600 M params × 10 M tokens is single-digit GPU-hours on a
rented A100/H100. The lane has no spare GPU (tiberius is production, pius/trajanus have none), so
either rent one or train on tiberius inside maintenance windows.

## 5. Cost and expected value

**Pilot (1 M tokens).** 2.5 h of lane time (or a rented sm90 build), 51 GB, ~1 week of engineering,
a few GPU-hours: enough to prove the pipeline and see whether acceptance moves at all. Expected
+0-2 pp acceptance — visible on a 447-draft cell (about +/-1 pp), but only +0-2 % decode, **inside the
6.4 % base decode spread**: a pilot can show a direction, not a throughput win, and a pilot that loses
is not conclusive. Its only real product is the pipeline.

**Real attempt (10-50 M tokens).** 1-5 days of lane time plus 0.5-2.5 TB, 3-6 weeks of engineering,
tens to low hundreds of dollars of rented GPU. Expected **+3-8 pp acceptance → +3-8 % decode** if the
2-bit taps are learnable at this capacity, with real downside risk (the 4-bit tuned pack lost 7 pp
and 6 % decode). The ceiling remains +15 % decode and 0 prefill.

Recommendation: **do not start it now.** The lane's open bottleneck is the prompt path (5.9 s/request
fixed cost, 41 % of engine wall time); round 17 also closed the cheap alternative (copy/edit text
already runs at the 8-row cap, and wider lookup windows do not run with DFlash2), so a refit is the
only remaining way to move acceptance - and it moves it by single-digit percent at best. Revisit
the refit if one of these becomes true:

1. upstream publishes a drafter trained on 2-bit outputs (then it is a download and a window, not a
   project);
2. a spare >=24 GB GPU and >=1 TB of scratch storage appear (removes the two binding costs);
3. decode throughput becomes the lane's top priority after the prompt path is done.

## 6. If it is started: staged plan

1. **P0 (no training).** Reproduce offline acceptance for the stock pack from a 100 k-token tap dump
   with `dflash2_ref.py`, so the offline number matches the served 85.3 %. Gate: offline within
   ±1 pp of served. This also validates the tap format end to end.
2. **P1 (1 M pilot).** Fine-tune, pack, evaluate offline on a held-out 100 k taps. Gate: +2 pp
   offline, text parity on a greedy copy/edit cell. If it moves less, stop — the pipeline cannot see
   a win the harness cannot measure.
3. **P2 (10 M).** Only after P1 clears: capture 10 M tokens (25 h of lane time or a rented build),
   train, offline eval, then one L-live + eval320 window. Gate: +4 pp served acceptance and decode
   +4 % on >=2 of 3 cells with eval320 within noise; otherwise revert to the stock pack.
4. **P3 (scale).** Only if P2 clears; 50 M tokens is the realistic point where a refit might reach
   the low 90s.

Revert is trivial throughout: the drafter is a file beside `draft_vocab.bin` and the serving config
names it; the stock pack stays in `/optane/strata-data/dflash2/`.

## 7. What this note does not claim

- It does not claim 99 % is physically impossible — it claims it is ~+14 % decode, needs a
  distribution match the stock drafter does not have, and that no measured drafter on hand is close
  on ordinary text (best on this pack: 85.3 % stock, 78.2 % tuned; the 97.5 % copy cell is the same
  stock drafter on verbatim text, not a second drafter).
- The +3-8 pp band in §5 is an estimate from the acceptance-to-decode mapping and the size of the
  data budget, not a measurement. The only measurements are the table in §1 and round 12's bound.
