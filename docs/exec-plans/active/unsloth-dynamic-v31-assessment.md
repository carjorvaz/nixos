# Unsloth Dynamic V3.1 for Qwen3.8-Flash-Next: assessment

Status: **assessed 2026-11-05; not adopted.** A quality lever worth a bounded experiment only if
quality becomes the priority over prefill speed and the disk work is acceptable. This note records
what the update is, why it does not drop into the current lane, the one technically plausible
variant, and the experiment plan.

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

## Verdict

Not adopted now: it is a model-quality/disk experiment, not a configuration knob, and the current
lane's measured bottleneck is prefill (now improved 5.7 % by the tensor-core unlock) rather than
quality. Revisit when (a) quality rather than speed is the priority, (b) a same-family i-quant
variant at ≤82 GB is available (or the current pack's source GGUF is no longer needed for rebuilds),
and (c) the DFlash2 drafter question is settled. The assessment is recorded here so the idea is not
re-derived from scratch next time; the outline above is the starting point.
