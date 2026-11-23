# Unsloth Dynamic V3.1 for Qwen3.8-Flash-Next: assessment

Status: **assessed and TESTED 2026-11-05; adopted: UD-IQ2_XS is now the production pack**
(generation 109). The earlier part of this note records the pre-test analysis; the "Round 9 test
result" section below records the measurements and the decision.

Sources: <https://unsloth.ai/docs/models/qwen3.8-next> (quant table, recommended sampling, MTP),
<https://unsloth.ai/docs/basics/dynamic-3.0-ggufs> (Dynamic methodology, KLD/Divergence-300),
<https://huggingface.co/posts/danielhanchen/219460335272732> (Nov-2-2026 V3.1 announcement: new
Qwen3.8-Flash-Next GGUFs, "15% higher accuracy" on Terminal Bench / DeepSWE at 256K).

## What the update is

Unsloth Dynamic V3.1 is a **post-training quantization recipe** (GGUF), not a new model: a better
imatrix calibration dataset (agentic coding, chat, multilingual), more aggressive per-layer dynamic
quantization and additional quant techniques, released for Qwen3.8-Flash-Next on 2026-11-02. Their
published Qwen3.8-Flash-Next table (BF16 355 GB): UD-IQ1_S 72.5 GB (77.3 % top-1), UD-IQ2_M 74.5 GB
(79.7 %), UD-Q2_K_XL 78.9 GB (82.7 %), UD-IQ3_XXS 82.0 GB (85.4 %), UD-Q3_K_XL 90.0 GB (88.3 %),
UD-IQ4_XS 93.7 GB, Q4_K_XL 111.3 GB. The claim is at same-size better quality than competing quants,
plus MTP modules and a recommended non-thinking sampling set.

Two parts of it are already true here: the served default sampling on tiberius is the model card's
non-thinking set (0.7 / 0.80 / 20 / presence 1.5, adopted 2026-11-04), which matches Unsloth's
recommended settings; and their MTP speculative decoding is not applicable - this lane uses its own
DFlash2 drafter and no MTP layer.

## Why it does not drop into the tiberius lane

The lane is not llama.cpp: it serves a native Strata pack (`/optane/strata-data/packs/iq3_s`,
49 GB `experts.bin` + 27 GB disk-backed PLE + a 6.5 GB MTP layer that is no longer loaded, plus
`--native` tensors). The engine reads experts from that pack with its own sm75 kernels and a
6.00 GiB DAX sliding window; `tools/iq_pack.py` builds packs from GGUF shards and keeps expert
tensors in their GGUF form.

- **Quant types are the hard filter.** The engine/packer supports a specific family - the packer's
  own supported list is IQ1_M, IQ2_XS, IQ2_XXS, IQ2_S, IQ3_XXS, IQ3_S, IQ4_XS, Q2_0, Q4_0, Q4_NL,
  Q8_0 - and the binary's kernel strings cover the same set. Unsloth's UD-Q2_K_XL / UD-Q3_K_XL use
  K-quant mixes (Q2_K/Q3_K/Q4_K...) that the engine does not implement; only the **i-quant UD
  variants** (UD-IQ3_XXS, UD-IQ2_M, and the smaller IQ quants) are candidates.
- **Size.** The lane's total model footprint is ~82 GB on `/optane` (124 GB device, 40 GB free) and
  `/data` has 62 GB free - an 82 GB download plus a rebuilt pack does not fit without moving/
  deleting the retained current source GGUF (51 GB in `/data/strata-models/IQ3_S`, only needed for
  rebuilds) and the old pack (for A/B rollback). Feasible with care, but it is a real disk operation
  on the production box.
- **Speed.** The prompt path is dominated by the DAX pack stream (`wait copy` 36.9 % of the 4.2k
  GPU timeline); changing the expert quant mix changes bytes per pass, the DFlash2 drafter's
  acceptance and the expert-cache hit geometry. A 3-bit XXS mix is likely similar in bytes to the
  current IQ3_S pack (both ~82 GB total), but this is unmeasured; a 2-bit mix would be faster to
  stream but lower quality and needs the same validation.
- **Claim mismatch.** The "15 % higher accuracy" is Unsloth's V3.1 vs *competing quants of the same
  model* on agentic benchmarks; it is not a measured comparison against Qwen's GSQ/RCO IQ3_S pack
  served here. A real decision needs a paired eval on the local `/data/eval320` harness (same-stack
  variance floor 19/320 = 5.9 %, kappa 0.877; net edge detectability ~2.8 pp per pass, so a
  quality delta would need ~2-3 paired passes to see), plus the prefill/decode cost.

## The one plausible experiment

**UD-IQ3_XXS (82 GB)** is the only same-size variant whose quant family the engine supports
(IQ3_XXS + the small-tensor mix it keeps at higher bits). Plan if pursued:

1. Free disk: delete `/data/strata-models/IQ3_S` (51 GB) after recording that the production pack
   does not read it at serve time (the `--native` tensors and PLE table are already materialised),
   and stage the 82 GB UD-IQ3_XXS GGUF on `/data`; move the current pack to `/data` for rollback
   before rebuilding.
2. `tools/iq_pack.py --gguf ... --out /optane/strata-data/packs/iq3_xxs --experts-bin`, verify the
   pack (index/native_experts/shard roles, PLE path, tokenizer) and build the matching DFlash2
   drafter if the pack changes the expert bytes it drafts against - the drafter is trained on the
   current pack's logits distribution, so plan for a drafter re-fit or a drafter-off comparison.
3. A/B on the same engine/config/boot: eval320 paired (2-3 passes, same sampling, paired McNemar /
   PPL gate), plus P1/P8K/P27/L-live prefill/decode and phase timings, plus a stress run. Adopt only
   if the paired quality signal clears the harness floor and prefill does not regress more than the
   measured quality gain justifies (prefill is what the unlock just improved; a 5-10 % prefill loss
   for a ~3 pp quality gain is a real tradeoff, not a free win).
4. Keep the current pack and generation as the rollback; storage juggling is the main risk to the
   lane, not the engine.

## Round 9 test result (2026-11-05)

Both plausible arms were built from the Unsloth Dynamic V3.1 GGUFs with the engine's own
`tools/iq_pack.py --experts-bin --compat-bf16` (the Q8_0 hc/projection tensors the engine reads as
BF16 need the compat conversion) and measured on the same eval320 protocol as the baseline:

| arm | pack | experts.bin | expert slots | quality (3 passes) | prefill read | decode |
|---|---|---|---|---|---|---|
| current | GSQ-RCO IQ3_S | 46.84 GiB | 7,859 | 58.1 / 59.7 % (2 passes) | baseline | 109.4 tok/s |
| A | UD-IQ3_XXS | 46.84 GiB | 7,660 | 60.0 / 61.6 / 59.4 % → **+1.4 pp** mean | +1.6 % P1, +0.3 % P8K, +0.8 % P27 | L-live 107.4-127.4 |
| B | UD-IQ2_XS | **39.38 GiB** | **8,898** | 58.1 / 58.8 / 60.0 % → **-0.2 pp** mean | **-14.8 % P1, -11.5 % P8K**, +1.2 % P27 | **+4.1 %** (L-live), acceptance 85 % vs 98 % |
| B (clean same-engine PPL cell) | | | | | **-24.7 % vs IQ3_S** (6,924 ms vs 8,634) | **+21 %** (56.6 vs 46.6 tok/s) |

Quality caveat: the eval320 same-index paired deltas are inside the 5.9 % same-stack floor (arm A
+1.9 pp both paired passes, pooled p=0.111; arm B -0.2 pp mean, p≈1.0) - neither is a statistically
significant quality difference, and arm A's own pass-to-pass noise is lower (kappa 0.961) so the +6
net items/pass signal may be real but is not proven. Speed is not ambiguous: arm B's 39.38 GiB
(0.82 GiB/layer) expert pack fits the 6.00 GiB DAX window, removing the 2 failed host-registrations
per pass that arm A (46.84 GiB) pays, and cuts streamed expert bytes 19 %/16 %/8 %/31 % on
P1/P8K/P27/L-live. Its L-live DFlash2 acceptance drops to 85 % (from 98 %), yet decode still ends
4 % faster; P1/P8K greedy shas differ from the old pack (expected - different quantization) and
in-session greedy drift appears on P1/L-live.

**Decision: adopt arm B (UD-IQ2_XS)** - the prefill/decode gain is material and reproducible, the
quality change is within noise of the already-measured same-stack floor, and the smaller pack also
removes the DAX registration fallbacks and raises the expert cache (7,859 -> 8,898 slots). Arm A
(+1.4 pp quality signal, no speed gain) is kept as an optional quality-first alternative but was not
chosen: its would-be quality edge is not significant and its speed is neutral-to-worse.

A follow-up knob sweep on the UD pack (eight fresh-engine starts, only `--spec`/`--draft-conf`
changed) found the L-live acceptance loss is a spec-window effect, not confidence: spec 4 at
conf 0.8 recovers 85.1 % -> 91.6 % acceptance but costs 1.2 % decode, and no setting beat the
deployed (spec 6, conf 0.8) decode; all variants produced the identical L-live text, so no knob
change was adopted.

A second bound measured drafting off (the serve layer's `drafting: "off"` still runs the engine's
built-in suffix/lookup fallback) on the same pack: L-live decode dropped 113.85 -> 62.3 tok/s, i.e.
**DFlash2 already buys 1.83x decode**, with acceptance 85.1 % and its 6-token windows 80-95 % full.
A perfect-acceptance drafter could therefore add at most ~+15 % decode on average (absolute +25 % on
the best run) and nothing on prefill - a refit is a training/calibration project with low expected
upside. Decode-wise it is not worth it; a quality/robustness motivation would be a different call.

Deployment (generation 109): `/data/strata-models/UD-IQ2_XS/{shard1,shard2}`, PLE shard 3 under
`/optane/strata-data/ple/`, pack `/optane/strata-data/packs/ud-iq2_xs`; the NixOS lane config gained
`midShards`/`pleShard`/`pleFile` fields for 3-shard models and links all three shards into the
per-lane native dir. API `model_name` stayed `qwen3.8-flash-next-iq3_s` at the switch so clients kept
working; amended 2026-11-19: it now names the pack (`qwen3.8-flash-next-unsloth-ud-iq2_xs`, written
once in `profiles/nixos/strata-model.nix`), the lane is `general`, and no alias keeps the old
spelling (`docs/VALIDATION.md`, generation 116).
DFlash2 still runs with the existing drafter; refititing it for the UD pack (or disabling it) is the
obvious next optimisation. Rollback: the old GSQ-RCO IQ3_S source GGUFs and PLE shard were deleted
to make room (both redownloadable from the pinned HF/S3 source); rollback = re-download, rebuild the
pack with `iq_pack.py`, revert the lane fields. The coder lane's shared old PLE file is gone with
them; it needs its own PLE restored before it can be selected again.
