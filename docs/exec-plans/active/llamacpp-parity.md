# llama.cpp parity with the Qwen vLLM fork on Turing

Status: active (2026-09-19).

## Goal

Determine, by measurement on tiberius's 22 GB RTX 2080 Ti, whether mainline
llama.cpp or beellama.cpp can serve the pinned Qwen3.8-27B at or above the
production vLLM fork's decode and prefill rates, and land the runtime that gets
closest. Non-goal: replacing the vLLM service without the same quality and
lifecycle gates.

## Reference

vLLM `tiberius-qwen38.service` (W4A16 + int4 KV + MTP4 + history lookup,
`mode=VLLM_COMPILE`), greedy, repeated-word and wikitext prompts, 280 W.
Measured 2026-09-19 on the same card and host:

| prompt | filler tok/s (acc) | wikitext tok/s (acc) |
| --- | --- | --- |
| 2k | 80.2 (2.85) | - |
| 8k | 83.0 (2.98) | 99.5 (3.54) |
| 32k | 73.7 (3.02) | 96.3 (3.85) |

The wikitext run is the same file (`/data/ab/quality-data/wikitext.txt`) and
the same `--text-file` stretching as the llama.cpp runs below.

## Method

One runtime at a time with the production service stopped, same 280 W limit,
`-ngl 99 -fa on`, `--parallel 1`, `--cache-ram 1024`, `--ctx-checkpoints 32`,
one warmup per prompt shape before the measured runs. Acceptance is
`1 + accepted/drafts` from llama-server's `/metrics`, the same convention as
vLLM's spec-decode counters. Step time is `acceptance / decode_tok_s`.

## Findings

### Base steps are at the same bandwidth efficiency
beellama v0.4.6, unsloth UD-Q4_K_M (16.4 GiB), q4_0 KV, no speculation:
28.4/27.1/22.8 tok/s at 2k/8k/32k (step 35.2 ms at 2k). vLLM's no-spec step is
29 ms for 13-14 GiB. Both run at ~465 GB/s; the fork reads ~1.7 GB less per
step because of its format (W4A16 + int8 embedding + int4 lm_head). Lower-bit
GGUF does not substitute: UD-IQ4_XS measured the same step time as
UD-Q4_K_M (54.3 vs 54.1 ms at MTP2), because i-quant dequantization is slower
per byte on sm75.

### The chat gap is the draft chain, not acceptance

beellama, UD-Q4_K_M, q4_0, depth sweep (filler):

| arm | 2k tok/s | acc @2k | step @2k |
| --- | ---: | ---: | ---: |
| MTP2 | 46.5 | 2.52 | 54.1 ms |
| MTP4 | 36.7 | 2.80 | 76.3 ms |
| MTP6 | 33.3 | 3.32 | 99.5 ms |

Each sequential MTP pass costs ~9-10 ms and buys ~0.2-0.3 accepted tokens.
vLLM's four passes cost 4.5 ms total: its draft runs an int4 head over a 40k
draft vocabulary, while llama.cpp re-runs a Q6_K 248k-vocabulary head
(~1.0 GiB) plus the MTP block (~0.35 GiB) every pass. Mainline b11050 is
7-10 % faster than beellama at identical acceptance (MTP4 39.3/41.9/38.4 vs
36.7/39.3/33.0; step 71.2 vs 76.3 ms at 2k). A standalone MTP sidecar and the
KVarN cache changed decode by noise only; KVarN remains a quality/memory tool.

DFlash2 is closed on this card for now. Both runtimes accept 3.735 tokens per
step at 2k (published claim) but the drafter pass costs ~65 ms: beellama
36.1 tok/s at 103.5 ms/step, mainline 37.9 at 98.5 ms/step.

### The ngram hybrid is a large, sampling-dependent win

Mainline b11050, UD-Q4_K_M, `--spec-type draft-mtp,ngram-mod` vs MTP alone:
| prompt | MTP2 tok/s (acc) | hybrid tok/s (acc) |
| --- | --- | --- |
| filler 2k | 48.8 (2.52) | 84.6 (9.54) |
| filler 8k | 48.6 (2.59) | 73.3 (7.81) |
| filler 32k | 39.6 (2.47) | 186.1 (25.4) |
| wikitext 8k | 52.0 (2.82) | 83.7 (5.73) |
| wikitext 32k | 42.4 (2.68) | 77.7 (10.33) |

That beats the fork on repeats and gets within 15-20 % of it on wikitext,
greedy. Under the model's production sampling (temperature 1.0, top_k 20,
top_p 0.95) it collapses: wikitext 8k sampled is 36.6 tok/s at acceptance 2.50
against 83.7 greedy, matching the documented reason the fork keeps its own
history lookup greedy-only -- point-mass proposals are accepted with `p(x)`
instead of `min(1, p/q)`. So the hybrid is a *greedy-client* feature.

### Second-round tuning (later 2026-09-19)

Leads from the r/LocalLLaMA mirror on pius (`/persist/reddit-mirror`,
2026-08/09 threads) produced a better set of flags. All wikitext, 32k context,
q4_0 KV unless noted:

| config | 8k greedy | 32k greedy | 8k sampled |
| --- | ---: | ---: | ---: |
| mainline MTP2 | 52.0 | 42.4 | ~40 |
| mainline MTP4, `p-min 0.5` | 54.5 | 40.0 | 39.5 |
| mainline MTP6, `p-min 0.75` | 56.0 | 40.3 | 40.9 (acc 3.27) |
| mainline ngram tuned (`ngram-mod,draft-mtp`, match 24, min 48, max 64) | 86.7 | 80.9 | 44.1 |
| ik_llama + ubergarm IQ4_KS, MTP4, q8_0 KV, `--ctx-checkpoints 0` | 57.7 | 40.9 | - |
| ik_llama + `ngram-mod` chain + MTP1 | **105.2** | 60.0 | 40.4 |

Key points:

- `--spec-draft-p-min 0.75` with `--spec-draft-n-max 6` is the best upstream
  chat config: it raises sampled acceptance to 3.27 tokens/step, matching the
  fork's 3.22, but the step still costs ~80 ms against the fork's ~38 ms.
- ik_llama.cpp with the ubergarm `MTP-IQ4_KS` quant (a 4.25 bpw MTP block plus
  a separate `output_extra.weight` head) is the fastest chat engine measured:
  57.7 tok/s at 8k. `--ctx-checkpoints 0` is mandatory for the hybrid model:
  with default checkpoints its 32k prefill dies allocating ~150 MiB per
  checkpoint.
- The ik `ngram-mod` + MTP chain reaches **105 tok/s at 8k on realistic text,
  above the fork's 99.5**, and 87/81 for the mainline tuned hybrid. Under
  production sampling every engine lands at 40-44 tok/s, so these are
  greedy-client wins.
- The mirror's 16 GB-VRAM study documents the same clamps independently
  (MTP `n=2` optimal without p-min; KVarN/no-KVarN decode differences are
  quality-tool not speed-tool) and adds the Turing-specific analysis: on
  sm75 the 48 Gated DeltaNet layers run a sequential FP32 scan, which is what
  bounds batched speculative verification on this architecture. The fork's
  custom sm75 GDN state kernel and split-KV verify attention are the likely
  source of its lower per-verified-token cost; a 22 GB 2080 Ti user in the
  archive reports 35 tok/s with `UD-Q4_K_XL` + MTP3, matching this campaign.
- The fork's author (iamMess) confirms in the archive that the 40k draft
  vocabulary is engine-agnostic, which is the strongest argument for the port
  in *What would close the gap*.

### Sampled traffic is the production case and it stays ~2x behind

The OMP client sends no sampling parameters, so the server applies the model's
`generation_config.json` (temperature 1.0, top_k 20, top_p 0.95). Under that
sampling mainline MTP2 measures 35.7 tok/s on filler at 8k (acceptance 1.95)
against vLLM's ~85 tok/s for the same workload. The relative gap matches the
greedy case.

### Prefill and long context are ~20 % behind, not 2x

Cold prefill with a unique nonce prompt, mainline hybrid (wikitext), against
the fork's measured cold TTFTs on the same host:

| prompt | llama.cpp tok/s (TTFT) | vLLM tok/s (TTFT) |
| --- | --- | --- |
| 8k | 687.7 (11.1 s) | 872 (8.35 s) |
| 32k | 600.3 (51.8 s) | 792 (40.4 s) |

Cached decode at 120k context measured 52.9 tok/s (acceptance 5.52) against the
fork's 63.8 tok/s at 128k. Prefill and the long-context tail are the closest
parts of the comparison; the gap is consistent with the fork's Turing Cutlass
tile and int4 attention staging.

### Long context: prefill, decode, and 262k

All runs use unique nonce prompts so prefill numbers are cold, and contexts
larger than the prompt so no context shifting contaminates speculation. Same
card, same day, greedy, wikitext.

| prompt | llama.cpp cold prefill | llama.cpp decode | vLLM cold prefill | vLLM decode |
| --- | ---: | ---: | ---: | ---: |
| 32k | 596 tok/s | 35-43 tok/s | 792 tok/s | 73.7 tok/s |
| 64k | 510 tok/s | 34-37 tok/s | 678 tok/s | 76.2 tok/s |
| 128k | 390 tok/s | 18-36 tok/s | 555 tok/s | not measured (49.8 is a 64k prompt in a 128k context) |
| 262k | 269 tok/s (IQ4_XS) | ~21 tok/s | 363 tok/s (248k) | ~25 tok/s (est.) |

Decode cells pair the prompt with a larger context (no context shifting); the
fork's 49.8 tok/s was measured with a 64k prompt in a 128k context, and no
128k-prompt decode exists on either engine. The prefill columns are single
prompt-length runs. The llama.cpp decode ranges are pre-kernel-build; the
final kernel-build numbers with explicit context and prompt are below.

#### Final kernel build, apples to apples (context > prompt, nonce prefill)

| context | prompt | config (all wikitext, greedy) | decode | acceptance | prefill |
| ---: | ---: | --- | ---: | ---: | ---: |
| 65536 | 32768 | MTP2, K f16 + V q4_0 | 48.5 tok/s (step 58.2 ms) | 2.82 | 586 tok/s |
| 131072 | 32768 | MTP2, K f16 + V q4_0 | 44.6 tok/s | 2.59 | 585-588 tok/s |
| 131072 | 32768 | MTP2 + ngram, K f16 + V q4_0 | 44.6-44.8 tok/s | 2.6-3.0 | 585-587 tok/s |
| 131072 | 65536 | MTP2, K f16 + V q4_0 | **43.9 tok/s (step 64.2 ms)** | 2.82 | 490 tok/s, 126 s TTFT |
| 131072 | 65536 | MTP2, K f16 + V q4_0, temp 1.0 | 30.7 tok/s | 1.97 | 488 tok/s |
| 131072 | 131072 | MTP2, K f16 + V q4_0 | 28.7-30.7 tok/s (step 75.2-75.8 ms) | 2.17-2.31 | 334 s cold |
| 262144 | 32768 | MTP2, IQ4_XS q4_0/q4_0 | 22.9 tok/s | 2.63 | 250 tok/s |
| 262144 | 32768 | MTP2 + ngram, IQ4_XS q4_0/q4_0 | 41.7 cold / 69.8 warmed | 2.59 / 5.08 | 594 tok/s |
| 262144 | 262144 | MTP2, IQ4_XS q4_0/q4_0 | 22.9 tok/s (step 114.6 ms) | 2.63 | 250 tok/s, 964 s TTFT |
| 262144 | 262144 | MTP2 + ngram, IQ4_XS q4_0/q4_0 | 20.9 tok/s (step 119.5 ms) | 2.50 | 251 tok/s, 964 s TTFT |

At the same operating point (64k prompt, 128k context) the fork measures 49.8
tok/s (step 58.5 ms) against llama.cpp's 43.9 (step 64.2 ms): **88 % of the
fork, up from 62 % pre-kernel** (30.7 tok/s at a 128k prompt is a different,
longer operating point). Under production sampling (temp 1.0, top-k 20,
top-p 0.95) the same config decodes 30.7 tok/s at acceptance 1.97, so sampling
costs about a quarter of the rate through acceptance alone. The step cost
tracks the filled prompt, not the configured context: 58.2 ms at 32k, 64.2 ms
at 64k, 75.2 ms at 128k, 114.6 ms at 262k. The remaining per-step difference
against the fork at 64k is 5.7 ms.

The two full-context rows (prompt == context) are context-shifting runs, as
vLLM's 248k number also was: llama.cpp re-prefills on the shift, which is why
one decode costs a full TTFT again. Under those conditions the ngram drafter
does not help (20.9 against 22.9 tok/s at a higher per-step cost); its value
is in the ctx > prompt, warmed-cache case (69.8 tok/s), which is also the
honest production shape.

- **Prefill is 25-30 % behind at every depth**, not 2x: the full cold 128k
  prefill is 317 s on llama.cpp against 236 s on the fork. ubatch size is not
  the lever: `-ub 512/1024/2048` measured 596/605/602 tok/s at 32k. The gap is
  the fork's Turing Cutlass tile and int4 attention staging.
- **Decode is behind at every depth**, from 32k (44-48 vs 73.7) to a 64k
  prompt in a 128k context (43.9 vs 49.8; 88 % of the fork), to a full 128k
  prompt (28.7-30.7; fork not measured at that prompt length). Sampled
  long-context with the best MTP config (`n-max 6`, `p-min 0.75`) is 19-21
  tok/s at 128k.
- **262k fit**: with `-c 262144` and q4_0 KV the model must be UD-IQ4_XS
  (14.25 GiB); UD-Q4_K_M fails at load (~22.3 GiB of weights+KV+state against
  22.5 GiB physical). IQ4_XS 262k runs at 21 GB VRAM, 269 tok/s cold prefill
  (16.3 min TTFT) and ~21 tok/s decode. Its i-quant penalty does not show up
  in prefill (394.6 vs 389.6 tok/s at 131k against UD-Q4_K_M) and decode step
  times are comparable; only the acceptance-driven rate differs.
- **Retrieval passes at 128k on both engines**: a unique code near the
  beginning was recovered correctly by llama.cpp (TTFT 317 s) and vLLM
  (TTFT 236 s). 262k retrieval was not run.
- ik_llama + ubergarm at 64k measured 486.6 tok/s cold prefill (close to
  mainline's 510) and 20-58 tok/s decode (ngram-dependent). At 128k with
  `--cache-ram 1024 --ctx-checkpoints 0` it prefills at 386.6 tok/s (mainline:
  389.6) but decodes only 9.8-10.5 tok/s, so the chain's 8k win does not carry
  to depth; mainline stays the best llama.cpp-family long-context decoder. The
  first 128k attempt thrashed the 7.5 GiB host and dropped SSH for ~15 min
  because ik defaults to an 8 GiB `--cache-ram` and the mainline arms had been
  bounding it at 2 GiB; a retry with 1 GiB was stable, and any future ik
  long-context profile must bound cache-ram and checkpoints.
- **Measurement hygiene**: when the prompt fills the configured context,
  llama.cpp shifts context and the ngram drafter can lock onto shifted
  history, inflating acceptance (a 32k filler run in a 32k context reported
  186 tok/s / acceptance 25; the same prompt in a 128k context decodes 35-43
  tok/s). Long-context speculation comparisons need ctx > prompt.

### Implementation experiments (later 2026-09-19)

Three engine-level experiments were built and measured on tiberius (source at
`/persist/llama-patched/src`, mainline b11050, CUDA 12.9, sm75, all FA pairs
compiled):

1. **Quantized-KV verify through the vec kernel (regression).** On Turing the
   attention dispatch sends single-token decode (q=1) to the vec kernel but the
   3-5 token verify to MMA_F16, which converts the whole K/V to f16 per layer
   per step. A patch added a 4-column vec template and routed q<=4 through it.
   Measured at identical settings (wikitext, q4_0 KV, MTP2): 64k 29.9 vs 38.8
   tok/s and 128k 16.8 vs 24.9 tok/s. The vec kernel scales poorly with
   `ncols` at D=256, so MMA+conversion is the better verify path; the patch
   was reverted.
2. **Dispatch relaxation for unaligned KV (correctness trap).** The vec kernel
   requires `K->ne[1] % FATTN_KQ_STRIDE (256) == 0`; otherwise quantized KV on
   Turing takes MMA. A microbenchmark (D=256, 20 Q heads, 4 KV heads, q=1,
   q4_0/q4_0) measured **1.77-1.81 ms/op at kv=32768 (aligned) against
   10.06 ms/op at kv=32767 (unaligned), a 5.6x cliff**. Relaxing the dispatch
   for Turing made the unaligned op fast (1.81 ms) but **numerically wrong**:
   masked unaligned cases fail the CPU-reference test with ERR 0.0136 against
   the 5e-4 tolerance. The 256 alignment is a correctness requirement of the
   mask/vec path, so the fix must pad the KV view and mask (with -inf padding),
   not relax the condition. End to end the relaxed patch changed nothing
   (128k no-spec 14.55 vs 14.20 tok/s), so production is not currently paying
   the conversion; the base gap is the real kernel cost.
3. **Base and spec cost decomposition at 128k** (mainline, UD-Q4_K_M, q4_0):
   no-spec base 70.4 ms/step; MTP2 with acceptance 2.35 94.5 ms/step, so one
   extra verified token costs ~24 ms against the fork's ~1.5 ms. Each MTP pass
   costs ~11.5 ms (marginal cost measured across the depth sweep) although its
   weights are only ~1.4 GiB (~3 ms): launch/sync/sampler/graph overhead, not
   bandwidth, dominates the draft chain.

An ngram parameter sweep at 128k measured 21-36 tok/s (best acceptance 3.82 at
24/48/64 against MTP2's 2.35); vLLM on the same prompt measured 49.8 tok/s.
Acceptance is the swing factor but not stable enough to beat the fork on
neutral text.

### KV cache type is a real speed lever on sm75 (later 2026-09-19)

Production-shaped FA microbenchmarks (D=256, 24 Q heads, 4 KV heads, q=1,
mask, aligned KV) on the patched tree:

| KV type | kv=32768 | kv=65536 |
| --- | ---: | ---: |
| q4_0 / q4_0 | 2164 us | 4242 us |
| f16 / f16 | **1394 us** | **2771 us** |

So the vec kernel is **1.55x faster with f16 KV than with q4_0 KV**, and
unaligned KV lengths are ~5.5x slower (they take the MMA path). The vec
kernel re-reads K/V once per Q head (GQA duplication: per-Q-head cost is
constant at 24 heads and at 4 heads), which is the structural attention cost
at depth.

End-to-end (mainline, UD-Q4_K_M, MTP2 unless noted, wikitext):

| config | 32k | 64k | 96k | 128k |
| --- | ---: | ---: | ---: | ---: |
| q4_0 / q4_0 | 36.5-38.8 | 38.8 | ~30 (est.) | 24.9 |
| f16 / f16 | 44.5 | 44.9 | - | n/a (VRAM) |
| f16 K / q4_0 V | 44.0 | - | 36.8 | **26.6** |
| f16 K / q4_0 V + ngram hybrid | - | **69.6** (acc 5.52, warmed) | 37.2 (acc 2.76) | **38.5** (acc 3.94, warmed) |

K f16 + V q4_0 fits 128k (about 5.4 GiB of KV with the 16.4 GiB model);
f16/f16 fits about 64k. The ngram-mod cache persists across requests, so
acceptance warms within a session, which is what produced the 69.6 tok/s
result (vLLM measured 76.2 on the same prompt) and the 38.5 tok/s at 128k
(vLLM: 49.8). Cold first runs are 41.8 and 28.2 tok/s respectively.

**Config guidance for the llama.cpp alternative**: use the strongest cache
that fits -- f16/f16 up to ~64k, K f16 + V q4_0 up to 128k, q4_0/q4_0 beyond
-- and keep the `ngram-mod,draft-mtp` chain on. The gain over q4_0/q4_0 is
+16 % at 64k and +7-13 % at 128k, and f16 K also removes that half of the KV
quantization error.

### Kernel plan: quantized K/V in the MMA path (next project)

Measured op costs at production shape (D=256, 24 Q heads, 4 KV heads, mask,
kv=32768) via `test-backend-ops` with the dispatch logger:

| KV types | q | kernel | us/op |
| --- | ---: | --- | ---: |
| q4_0/q4_0 | 1 | vec | 2146 |
| f16/q4_0 | 1 | vec | 2912 |
| f16/f16 | 1 | mma_f16 | 1393 |
| q4_0/q4_0 | 3 | mma_f16 + K/V conversion | 4792 |
| f16/f16 | 3 | mma_f16 | 3104 |

The fast path is `mma_f16`, but it requires f16 K/V: quantized caches are
converted to f16 **per layer per verified step** (about 12 ms at 128k for V
only with K f16, about 23 ms for K+V with q4_0). Teaching
`flash_attn_ext_f16_load_tile` in `ggml/src/ggml-cuda/fattn-mma-f16.cuh` to
dequantize q4_0/q8_0 while staging the shared-memory tile would delete that
conversion, unlock the tensor-core path for quantized caches at every query
count, and is the single largest remaining lever. The loader is the only
place that touches K/V bytes (called from four sites for K and V); it keeps
the 16-byte chunk/swizzle structure, so a quantized variant loads 4 bytes of
nibbles plus a scale and expands them to the 16-byte f16 chunk. The
supporting changes are `need_f16_K/V` and the alloc-size path in `fattn.cu`,
plus type-templating the MMA case instantiation. The test harness in
`/persist/llama-patched/src/tests/test-backend-ops.cpp` already has the
production-shaped cases and CPU-reference correctness gate for this work.

A second, smaller lever is the vec kernel's q4_0 KQ dot, which reads 4 bytes
per lane at an 18-byte block stride and re-reads each nibble byte twice (once
per shift); a 16-byte-load variant with shuffle distribution mirrors the
staging fix that took the fork's int4 attention from 27 to 100+ GB/s.

### Quantized K/V dequant in the MMA tile loader (built and validated)

The next project in the plan above was implemented: `flash_attn_ext_f16_load_tile`
in `ggml/src/ggml-cuda/fattn-mma-f16.cuh` now has a quantized branch that
dequantizes a 16-byte f16 chunk from q4_0/q8_0 in shared-memory staging,
with safe unaligned loads (`ggml_cuda_memcpy_1<N,2>`, since q4_0 blocks are 18
bytes) and the correct q4_0 packing (byte j holds element j in the low nibble
and element j+16 in the high nibble). The kernel, case launcher, dispatch and
allocation-size logic are type-templated, and the f16 conversion is skipped
when the pair is supported.

Correctness: the CPU-reference suite passes 12/12 for (F16,Q4_0) and
(Q4_0,Q4_0) at kv 256/512/1024, q=1 and q=3, masked; a 32k retrieval check
through the patched kernel passes; and the GSM8K battery on the patched build
scores **96.5% (n=200, 372 mean tokens)** against the fork's published 94.5%.

Perf at production shape (kv=32768, D=256, 24 Q heads, 4 KV heads, mask):

| K/V | q | before | after |
| --- | ---: | ---: | ---: |
| q4_0/q4_0 | 1 | 2146 (vec) | 2570 (native) -- **keep vec** |
| f16/q4_0 | 1 | 2912 (vec) | **1739** |
| f16/f16 | 1 | 1393 (mma) | 1393 |
| q4_0/q4_0 | 3 | 4792 (mma + conversion) | **2636** |
| f16/q4_0 | 3 | ~3104-4792 | **1883** |

So the dispatch keeps the vec kernel for single-token decode when K is
quantized, uses native MMA for single-token decode with f16 K + q4_0 V, and
native MMA for every verify (q=2..16). Prefill-sized batches (q>16) keep the
f16 conversion: the in-kernel dequant costs 22% there (400 vs 514 tok/s at
64k), while it is a large win for the small batches the conversion otherwise
dominates.

End to end at a 128k prompt (K f16 / V q4_0, MTP2, wikitext): step
82.4 -> **75.2 ms**, decode 26.6 -> **30.7 tok/s**, cold prefill unchanged
(~334 s). At a 64k prompt in the same 128k context the clean build measures
**43.9 tok/s at step 64.2 ms** against the fork's 49.8 at 58.5. At 262k
(IQ4_XS, q4_0/q4_0): step 135.8 -> **114.6 ms**, decode 21.1 -> **22.9 tok/s**
at acceptance 2.63 (25.0 at the pre-patch acceptance of 2.86). A 32k retrieval
check through the patched kernel passes, and the CPU-reference suite is 12/12.

### MMVQ activation re-reads: the wide-batch cliff (2026-09-20)
The Turing MMVQ table picks `rows_per_block = 2` and 2-4 warps for batches of
2-8. Each block loads the activation vector for every column it computes, so the
activation L2 traffic scales as `ncols / rows` times the weight traffic. At
n=3 the activations are already 3x the weights, at n=8 8x: the kernel stops
being DRAM-bound and rides the L2 limit instead. Measured on the production
shapes (m=17408/10240, k=5120, GB/s of weights):

| batch | before | after (`rows_per_block=4`, 1 warp) |
| ---: | ---: | ---: |
| 1 | 484-552 | 484-552 (unchanged) |
| 3 | 414-438 | **466-535** (+10-24 %) |
| 5 | 305-376 | **364-456** (+19-21 %) |
| 8 | 195-265 | **222-326** (+15-20 %) |

One warp per block also measured faster for the k-quant and i-quant classes
(`Q2_K`, `Q3_K`, `Q4_K`, `Q5_K`, `IQ4_NL`, `IQ4_XS`) at n=2-4; `Q6_K` keeps 4.
The CPU-reference suite passes 36/36 on the production shapes at n=1/3/5 with
the new table.

End to end at 64k context, 32k prompt, K f16 + V q4_0, greedy wikitext:

| config | decode | acceptance | notes |
| --- | ---: | ---: | --- |
| base, no speculation | 25.0-25.3 tok/s | - | unchanged |
| MTP2 | 47.0 tok/s | 2.59 | was 44.5 |
| MTP3 | 42.0 tok/s | 2.57 | see below |
| **MTP4** | **54.4 tok/s** | **4.20** | was never competitive |
| MTP6 | 42.4 tok/s | 4.10 | |
| MTP8 | 30.2 tok/s | 3.26 | verify batch of 9 falls off the MMVQ path |

Deeper drafts only became viable after this fix: at n=5 the untuned kernel ran
at ~310 GB/s (45 ms for the weights alone), which is why the earlier depth
sweeps concluded MTP2 was optimal. MTP4's per-position acceptance is
(0.906, 0.844, 0.656, 0.562).

**Anomaly worth reporting**: odd `n_max` values lose the last draft almost
completely (per-draft acceptance 0.52 for n_max=3 and 0.53 for n_max=6 against
0.80 for n_max=2/4), and `n_max=8` *lowers* accepted length (3.26) versus
`n_max=4` (4.20). Even values between 2 and 4 are the practical range on this
model; the mechanism is not yet identified (draft generation and verification
both look position-clean when measured directly).

**Where the tuned MTP4 step goes** (instrumented server, 64k context, K f16 +
V q4_0):

| prompt | verify (n=5) | draft (4 passes) | sample+accept | acceptance | decode |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 8k | 50.9 ms | 12.5 ms | 1.1 ms | 2.86 | 44.5 tok/s |
| 16k | 55.0 ms | 12.8 ms | 1.6 ms | 3.85 | 56.2 tok/s |
| 32k | 60.3 ms | 13.9 ms | 1.6 ms | 3.7-4.2 | 49.9-54.4 tok/s |

The verify pass grows 0.28-0.57 ms per 1k tokens of context, ~30x more than the
KV bytes involved, and its internal accounting (nsys, n=5) is roughly 23-27 ms
of MMVQ plus ~13 ms of small ops and **~14 ms of kernel-launch gaps** across
~2450 kernels per pass (513 `quantize_q8_1`, 319 `rms_norm_f32`, 178
`k_bin_bcast`, 162 `cpy_scalar`). The gaps are now the second-largest single
item after MMVQ, and MMVQ's own fusion path is disabled for batches > 1 by
`ggml_cuda_should_fuse_mul_mat_vec_q` (`dst->ne[1] != 1` returns false), so the
activation quantization runs as 513 separate kernels per pass. That is the
next decode lever after this table.

**Nsight Compute on MMVQ at the decode shape (2026-09-21)**: `mul_mat_vec_q`
for Q5_K, m=17408, k=5120, n=5 (the largest single class of work in a verify
pass) reports DRAM throughput **59.6 %** of peak (386 GB/s), **L2 hit rate
41 %**, achieved occupancy **34.8 %** (theoretical 37.5 %), compute (SM)
throughput 55 %, and one instruction issued every 5.0 cycles. No unit is
saturated and occupancy is healthy, so the kernel is latency/issue-bound.

The structural inefficiency is the activation term: per k-element a block reads
`ncols x 1.125` bytes of q8_1 activations against `rows x bpe` bytes of weights,
i.e. 2.5x the weight traffic at rows=4, ncols=5 for Q4_K. More rows per block
divides that term, but the accumulator arrays are per-thread
(`tmp[ncols][rows]`), so rows=8 costs 40 registers and measured **worse** on the
k-quants (Q4_K 327 vs 363 GB/s at n=5); rows=6/8 only help IQ4_XS. The rows and
warp table is therefore at its measured optimum for this geometry, and a real
gain here needs a different small-batch GEMM (smem-staged weights, tensor-core
int8 tiles for n<=8) rather than a knob - the same class of project as the FA
kernel but with less headroom, since the kernel already reaches 60 % of DRAM
peak while doing 55 % compute work.

**Three more closed avenues (2026-09-21)**:

1. **`--spec-draft-p-min`** (draft stop threshold): measured with a *fixed*
   prompt at a 16k prompt, all in one session - p_min 0.0: 56.1-56.7 tok/s
   (acc 3.73), 0.25: 56.2-57.1 (3.82), 0.5: 55.8-57.3 (3.79), 0.75: 51.0-52.2
   (3.53). No effect below 0.75; an apparent +25 % at 0.5 seen earlier was
   nonce noise (the arm harness randomises the prompt per invocation).
2. **Turing MMQ tiles**: `I=64` with matched threads passes the CPU-reference
   suite (16/16) - unlike `I=128` with 128 threads which silently computes
   wrong results - but is **34 % slower** at n=512 (66 % of baseline across the
   production shapes); `I=64`/256 threads produces no result. The Ampere tile
   table stands; MMQ throughput (46-55 TFLOP/s) is not config-limited.
3. **Removing the Turing `ncols1` cap for decode** (`GGML_FA_NO_TURING_SMALL`):
   identical performance (+/-3 %) at every decode shape, which also disproves
   the "K/V is re-read once per query token" model - nb=1 and nb=5 on the same
   64k KV differ by only 21 %, so the K/V tile is already shared across the
   query tokens and the kernel is latency-bound as the ncu data showed.

**Register-staged loader attempt (2026-09-21)**: the loader was rewritten so a
thread stages all of its 16-byte chunks in registers before writing shared
memory (loads in flight together instead of load/store interleaved), with the
chunk size promoted to a template parameter so the staging array indices are
compile-time. Measured against the baseline:

| shape | staged | baseline | delta |
| --- | ---: | ---: | ---: |
| kv=32768, q=1, f16 K | 1394 us | 1776 us | **-22 %** |
| kv=65536, q=1, f16 K | 2889 us | 3462 us | **-17 %** |
| kv=8192, q=1, f16 K | 370 us | 436 us | -15 % |
| kv=8192, q=5, q4_0 K | 701 us | 746 us | -6 % |
| kv=65536, q=5, q4_0 K | 5345 us | 5604 us | -5 % |
| kv=8192, q=5, f16 K | 574 us | 536 us | +7 % |
| kv=65536, q=5, f16 K | 4433 us | 4193 us | +6 % |

So the idea is sound but only pays for single-token queries (the draft passes,
where it is worth ~3 ms/step at long context) and for the quantized-K path;
for the q=5 verify with f16 K - the shape that dominates production - the
extra register pressure costs more than the latency it hides. Reverted rather
than special-cased: the net across a step is negative for the configs that
matter. The remaining headroom really is a purpose-built kernel (flash-decoding
style split-KV with online-softmax merging), not a patch to this loader.

**Why the existing 2-stage pipeline cannot be reused on Turing (2026-09-21)**:
the kernel already contains the exact structure needed - a K-tile preload one
iteration ahead, with `last_iter` handling - but the branch is guarded by
`get_nstages() = cp_async_available(cc) && ncols2 >= 2`, and inside it
`static_assert(!oob_check)`. `oob_check` is true whenever the KV length is not
a multiple of the tile size, which is *always* the case during autoregressive
decoding (the length grows by 1-5 per step). So the pipelined path is only
reachable for aligned KV - benchmarks, not production - and reproducing the
pipeline for unaligned KV means rewriting the tile loader and its bounds
handling, not flipping a flag. That is the honest scope of the remaining
long-context work: a Turing FA kernel with register/smem double buffering that
also handles partial tiles, worth ~30 % of the decode step at 64k and ~46 % at
230k.

**L2 prefetch attempt on the non-`cp.async` loader (2026-09-21)**: since
Turing lacks `cp.async` but does have `prefetch.global.L2`, the tile loader now
issues one prefetch per 128 B of the *next* `nbatch_fa` tile. Measured on the
production shapes it is **5-8 % slower** (kv=65536, q=5: 6049 us vs 5604 us for
q4_0 K/V, 4447 vs 4193 for f16 K; only kv=32768/f16 K improved, 1715 vs
1776 us). The sequential tile walk is evidently already well served by the
hardware's streaming behaviour, and the extra instructions cost more than the
latency they hide. Reverted. Together with the config sweep, the kernel-choice
tests (vec/tile) and the masking argument, this closes every low-effort option:
the remaining fix is a loader that keeps the next tile's data in registers
while the current tile is consumed - i.e. a Turing software-pipeline - which is
a rewrite of the loader rather than a tuning change.

**Nsight Compute verdict on the FA kernel** (same shape, kv=8192, nb=5):
duration 986 us, **achieved occupancy 12.5 %** (8 warps/SM), **issued warps per
scheduler 0.12**, memory throughput 9.4 %, and **52 % of stall cycles are
long-scoreboard** (waiting on global K/V loads). The kernel is latency-bound
with almost no parallelism; the multi-stage preload path that would hide those
loads is `cp.async`-only and therefore dead code on Turing.

Constraints found while trying to raise occupancy (all verified by build):
`nbatch_fa` must be a multiple of 32 and >= 32, `nthreads` 256+ breaks the
`ncols == 8` template family (zero-sized fragments / "bad loop size"),
`nstages_target <= 2`, and the shared K+V tile at `nbatch_fa=64`, D=256 is
64 KiB, which caps residency at two blocks per SM no matter what the occupancy
target says. So the ~30 % of the decode step this kernel owns cannot be bought
back with configuration - it needs a Turing-specific loader that stages the
next K/V tile in registers while the current one is consumed (the Ampere path
does this with `cp.async`).

Two related measurements: at a 262k context the KV cache (q4_0/q4_0) plus the
IQ4_XS body already uses 21.3 GiB of 22.2 GiB, so the f16 K option that is 25 %
faster in the FA microbenchmark (f16/q4_0 4193 us vs q4_0/q4_0 5604 us at
kv=65536) does **not** fit there; and a masked sliding window for the draft
layer would not help either, because the FA kernel reads every KV tile
regardless of the mask.

**The long-context bottleneck is the flash-attention kernel (2026-09-21)**.
Profiling the decode window at a 64k prompt (IQ4_XS, q4_0 KV, MTP4) shows
`flash_attn_ext_f16` at **1.42 ms per call**, 75 ms of the 209 ms GPU time -
36 % of decode GPU, against 112 ms for all MMVQ combined. Isolating the
production shape in the backend benchmark (D=256, 24 Q / 4 KV heads):

| KV | q | K / V | FA time | KV read | effective BW |
| ---: | ---: | --- | ---: | ---: | ---: |
| 8192 | 5 | f16 / q4_0 | 536 us | 6.5 MiB | 13 GB/s |
| 32768 | 1 | f16 / f16 | 1394 us | 33.5 MiB | 24 GB/s |
| 32768 | 1 | q4_0 / q4_0 | 2189 us | 18.9 MiB | 8.6 GB/s |
| 65536 | 5 | q4_0 / q4_0 | 5604 us | 37.7 MiB | 6.7 GB/s |

The kernel scales linearly with KV but runs **25-90x below the DRAM bound**
(587 GB/s measured) and 1.4 TFLOP/s (2.7 % of Turing's fp16 tensor peak), which
is why the verify pass grows 0.51 ms per 1k tokens and why the fork - whose
Turing attention stages int4 K/V - pulls ahead at 200k+.

What was tried and did *not* move it: `nbatch_fa` 32/64/128/256,
`occupancy` 1/2, `nthreads` 64/128/256, `nbatch_K2/V2` 32/64/128,
`nstages` 4, and both alternative kernels (vec: 17.6 ms at 64k, tile: 16.5 ms
- 3x and 2.9x slower than the MMA path). The grid is
capped by runtime occupancy: with `nbatch_fa=64` and D=256 the shared-memory
tile (64x256x2 B) allows only one block per SM, so stream-k launches 68 blocks
and each iterates 60+ KV tiles serially. Root cause is structural: Turing has
no `cp.async`, so the tile loads cannot overlap the MMA compute, and the kernel
is written for the Ampere pipeline. A Turing FA kernel with explicit
register-staged double buffering (or a KV-split decomposition with online
softmax merging that runs at high occupancy) is the project that closes the
long-context gap.

**Reduced draft vocabulary, measured (2026-09-21)**: the qwen35 MTP graph now
accepts a smaller `blk.N.nextn.shared_head_head.weight` plus a `d2t` mapping
(`patches/`-side tree commit `9c1e156`; the same fill+set_rows pattern the
dflash drafter uses). With a 46,883-token subset (all tokens seen in an
18.9M-token wikitext+code corpus, plus every token of 34k generated output):

| config | head bytes/pass | step | acceptance | decode |
| --- | ---: | ---: | ---: | ---: |
| stock head (Q6_K, full vocab) | 994 MiB | - | 3.73-3.85 | 43.4-45.5 |
| Q4_K full head (fast-draft) | 682 MiB | - | 3.85 | 46.5-52.3 |
| Q4_K 46.9k-row head + d2t | 135 MiB | ~-15% | 3.40-3.50 | 49.3-49.8 |
| control: Q4_K 248k-row head + d2t | 682 MiB | +(scatter cost) | 3.82 (exact match) | 50.5-52.3 |

The step gain and the acceptance loss cancel, so the restricted vocabulary is
**not a win at this subset size** and was removed from the model set. Two
things are established: the scatter path is correct (the 248k control
reproduces the full-head acceptance exactly, per position), and only 0.4% of
the draft's argmaxes fall outside the corpus-derived subset - yet position-0
acceptance drops from 0.939 to 0.757, which the vocabulary size alone should
not explain. That gap is the open question (candidate explanations: the
`p_min` draft-stop gate reacting to the renormalised distribution, or subtle
numerical differences in the scattered logits). The capability is kept in the
tree because a *better* subset (derived from the draft distribution rather
than a text corpus) is the obvious follow-up.

**Open anomaly at very long context (2026-09-21)**: at a 230k-token prompt (IQ4_XS
body, q4_0 KV, MTP4) the prefill runs at **300 tok/s** but the decode step is
**181 ms** against 72 ms at a 32k prompt - +0.55 ms per 1k tokens of context,
about 30x the KV bytes the attention actually touches. Decode lands at
20.7 tok/s (acceptance 3.75) against the fork's ~25 tok/s estimate at 248k.
Candidates for the next session, in order: the speculative rollback path
(`--ctx-checkpoints 0` makes it a FULL rollback; the state copy for 48 GDN
layers is context-independent, so this needs a profile), the FA stream-k
decomposition at very long KV (Turing only enables it below 75% tile
efficiency), and the sampler over 5 x 248k logits. A no-speculation run at the
same context separates the spec machinery from the kernels and is the first
measurement to take.

**Multi-run decode at 64k/32k with the final stack** (MTP4 + fast-draft head,
K f16, three distinct prompts per config): **51.6-56.2 tok/s** (acceptance
3.73-4.20), mean ~53.7 - up from 44.5 at the start of the session. The
ngram hybrid on the same stack stays bimodal (37-56 tok/s cold, up to 160 tok/s
once the ngram index matches the text), because its proposals displace the
MTP ones when there is no repetition to exploit; it is a workload-specific
option, not a default.

**Best measured configuration matrix (2026-09-21, all with the tuned kernels)**:

| context | prompt | KV | spec | ub | prefill | decode |
| ---: | ---: | --- | --- | ---: | ---: | ---: |
| 64k | 32k | K f16 + V q4_0 | MTP4 + fast-draft head | 2048 | 622-626 tok/s | 50-52 tok/s |
| 64k | 32k | K f16 + V q4_0 | MTP4 (no fast draft) | 512 | 609-613 tok/s | 48.6-49.4 tok/s |
| 128k | 64k | K q8_0 + V q4_0 | MTP4 + fast-draft head | 512 | 520-526 tok/s | 47.6-49.2 tok/s |
| 262k | 262k | q4_0 + q4_0 (IQ4_XS body) | - | 512 | 291 tok/s | n/m |

Quality gates on the final stack: GSM8K 97.0% (n=200) with MTP4, retrieval
passes at 32k/64k contexts, and the FA/MUL_MAT CPU-reference suites pass
(30/30 and 40/40).

**128k config unlocked with K q8_0 + fast-draft head** (2026-09-21): the
fast-draft model costs 682 MiB of VRAM, which the 128k configuration did not
have (MTP4 needed `-ub 128` and even that was at 22060/22184 MiB). Switching the
K cache to q8_0 frees 2.1 GiB, which fits the fast-draft head *and* the full
`-ub 512` compute buffers. The conversion path for q8_0 K costs ~3 ms/step at
128k but the head saving is larger, and the f16 KV read traffic halves:

| 128k context / 64k prompt | prefill | decode | acceptance |
| --- | ---: | ---: | ---: |
| stock head, MTP4, `-ub 128`, K f16 | 414-416 tok/s | 44.2-49.9 tok/s | 3.85-4.38 |
| **fast-draft head, MTP4, `-ub 512`, K q8_0** | **520-526 tok/s** | **47.6-49.2 tok/s** | 4.23-4.38 |
| vLLM fork (same operating point) | 555 tok/s | 49.8 tok/s | 2.9 (implied) |

So at the fork's own long-context operating point llama.cpp is now at 94% of its
prefill and ~99% of its decode. Below 64k context K f16 remains faster than
q8_0 (the conversion cost is not amortised), so the configuration split is:
`K f16` up to 64k, `K q8_0` at 128k and beyond.

**Memory frontier at 128k**: with K f16 + V q4_0 the 128k configuration sits at
avoid 22.0 GiB, so MTP4 only fits with a smaller ubatch:

| 128k ctx, 64k prompt | prefill | decode | acceptance |
| --- | ---: | ---: | ---: |
| MTP2, `-ub 512` | 490 tok/s | 43.9 tok/s | 2.82 |
| MTP4, `-ub 128` | 414-416 tok/s | 44.2-49.9 tok/s | 3.85-4.38 |

Decode varies with the run's nonce (acceptance-driven), prefill pays ~15 % for
the smaller ubatch. `-ub 256` loads but dies during a 64k-token prefill, and
quantizing the draft context's KV does not free enough. Native q8_0 K support
would free 2.1 GiB and lift this constraint, but the f16-conversion path for
q8_0 K fails the prefill-shaped FA correctness case ({kv=4096, nb=512}) and
needs investigation first.

### Full step decomposition and the bandwidth ceiling (2026-09-20)

The speculative step was instrumented in the server itself (timers around the
verify `llama_decode`, `common_sampler_sample_and_accept_n`, and
`common_speculative_draft`). At 64k context, 32k prompt, MTP2, K f16 + V q4_0:

| phase | per step | share |
| --- | ---: | ---: |
| verify `llama_decode` (n=3) | 49.6 ms | 86 % |
| draft generation (2 MTP passes + head) | 7.3 ms | 13 % |
| sample + accept | 1.0 ms | 2 % |
| **total** | **57.9 ms** | (43.1 tok/s at acceptance 2.49) |

The same base model without speculation runs a single pass in 39.6 ms, so the
verify batch's three tokens cost +25 % over one token. A full nsys accounting of
one verify pass (49.9 ms span, 44.6 ms GPU, 2450 kernels) is 82 % MMVQ:

| kernel | ms | share |
| --- | ---: | ---: |
| `mul_mat_vec_q` (513 calls, 71.5 us avg) | 36.7 | 82 % |
| `gated_delta_net_cuda` (48) | 1.24 | 2.8 % |
| `flash_attn_ext_f16` (18) | 1.18 | 2.6 % |
| `concat_non_cont` (48) | 1.14 | 2.6 % |
| `rms_norm_f32` (319) | 1.03 | 2.3 % |
| `quantize_q8_1` (513) | 0.88 | 2.0 % |
| everything else | ~1.5 | 3.4 % |

MMVQ reads the full 15.3 GiB of weights per verify pass, so 36.7 ms means
**417 GB/s** of effective bandwidth. A purpose-written read-only CUDA kernel on
this card measures **581-587 GB/s** (94-95 % of the 616 GB/s spec), so the
decode path is at ~71 % of what the hardware can actually stream. The per-grid
breakdown shows where the loss is: the large FFN matrices reach 550-605 GB/s
(89-98 % of the measured ceiling) while the small per-layer projections
(GDN `attn_qkv` 29.5 MiB, `attn_gate`/`ssm_out` 17.6 MiB, attention `attn_q`)
run at 310-450 GB/s. Decode is therefore close to bandwidth-bound; the
remaining headroom is in the small-matrix kernels and in the ~5 ms of
kernel-launch gaps that 38 kernels per layer produce.

### Prefill is MMQ plus attention (2026-09-20)

nsys on a cold 32k-prompt prefill at 64k context (53.6 s span, 51.4 s GPU,
161k kernels, no speculation):

| kernel | ms | share |
| --- | ---: | ---: |
| `mul_mat_q` (30,752 calls, 1.03 ms avg) | 31,589 | 61.5 % |
| `flash_attn_ext_f16` (1024 calls, 10.0 ms avg) | 10,279 | 20.0 % |
| `gated_delta_net_cuda` (3072) | 4,152 | 8.1 % |
| `quantize_mmq_q8_1` (30,752) | 1,091 | 2.1 % |
| silu / rms_norm / bincast / concat / ssm_conv / stream-k fixup | ~3,500 | 6.8 % |

MMQ sustains ~56 TFLOP/s here (54 GFLOP/token, 611 tok/s) and the attention
kernel only ~20.5 TFLOP/s, so prefill attention was the cheap lever: the
launcher picks `ncols2 = 8` for `gqa_ratio > 4`, and on Turing the query tile is
capped at `ncols1 = 32/ncols2 = 4` rows, which multiplies K/V re-reads. The
64/ncols2 tile does not exist for sm75 it crashes (see below), but forcing
`ncols2 = 1` (query tile 32) is valid and measured:

| config | 32k prompt | 128k prompt | decode (no spec) |
| --- | ---: | ---: | ---: |
| `ncols2 = 8` (old default) | 606-615 tok/s | 383-387 tok/s (TTFT 319-322 s) | 25.0-25.3 tok/s |
| `ncols2 = 4` | 604-611 tok/s | - | - |
| `ncols2 = 1` (new default) | 629-640 tok/s | **429-431 tok/s (TTFT 287-288 s)** | 25.0-25.4 tok/s |

About **+4 % prefill at 32k and +12 % at 128k** (the K/V re-read that the tile
size controls grows with context), decode untouched. The FA correctness suite
was extended with prefill-shaped cases on the production geometry (D=256,
24 Q / 4 KV heads, q=32 and q=512, kv=1024/4096, F16 and Q4_0 K) and passes
20/20 with the new default.

The change is gated to Turing + prefill-sized batches + `gqa_ratio > 4`, and an
env override (`GGML_FA_NCOLS2=1/2/4/8`, `GGML_FA_NO_TURING_SMALL=1`) is kept in
the tree for future sweeps; `GGML_FA_NO_TURING_SMALL` reproduces the crash that
justifies the Turing tile cap.

Negative results worth keeping:

- **MMQ for the verify batch is slower.** Forcing the k-quants through MMQ at
  n=3 (the tuning other architectures use) costs 66.6 ms/step against MMVQ's
  57.8 ms. The dispatch default stands.
- **The sampler chain is not the overhead.** A minimal chain (`--top-k 1
  --top-p 1.0`) gives 57.9 ms/step against the default 57.8 ms.
- **The Turing `ncols1 = 64/ncols2` FA tile crashes** for D=256 (that is why the
  Turing special case exists); only `ncols2` reductions are available.
- **The 14 ms "missing" step time was inside the verify pass**, not in host
  code: the instrumented phase sum (49.6 + 7.3 + 1.0) accounts for the whole
  step, and the in-pass kernel gaps are ~5 ms of launch tails.

### Where a draft step goes (instrumented)

A temporary timer around the MTP draft pass (`llama_decode` launch,
`llama_synchronize`, sampler) reports, at 64k:

| component | per pass |
| --- | ---: |
| host launch of the draft decode | 1.3 ms |
| GPU work of the draft pass | 3.1 ms |
| sampler after the sync | 0.007 ms |
| **total** | **4.4 ms** |

The marginal cost of one more draft depth is ~8.7 ms by the numbers above
(5 ms for the extra verified token, 3.7 ms per draft pass) against ~11.5 ms
measured on the instrumented build, whose per-pass synchronization inflates the
step. Deeper drafts stay closed with the cheaper verify too: MTP2 44.1 tok/s
(step 64.0 ms) against MTP4 43.6 (step 97.1 ms) at 64k, both instrumented.

### What would close the gap

Ranked by measured headroom on this hardware (Turing, 587 GB/s practical DRAM
read, int8 tensor cores):

1. **Prefill MMQ tiles for sm75.** Prefill is 61.5% MMQ at ~56 TFLOP/s effective
   (54 GFLOP/token at 611-640 tok/s). Turing uses the Ampere tile table
   unchanged (`nthreads=256`, `I=128`, `J` up to 128); a Turing-specific
   `I`/`J`/occupancy sweep is the largest untouched prefill lever. The FA tile
   fix is done (+4% at 32k, +12% at 128k).
2. **Small-matrix MMVQ on the verify path.** The verify pass is 82% MMVQ and
   reads 15.3 GiB at 417 GB/s (71% of the measured 587 GB/s ceiling). Big FFN
   matrices already run at 89-98% of the ceiling; the GDN projections
   (`attn_qkv` 29.5 MiB, `attn_gate`/`ssm_out` 17.6 MiB) and `attn_q` run at
   310-450 GB/s. Fixing those is worth ~4-6 ms of the 49.6 ms pass.
3. **Shrink the draft pass.** The draft costs 7.3 ms/step because two MTP
   passes each read the full 994 MiB output head. A restricted draft vocabulary
   (the fork's 40k-row int4 head) cuts that ~6x and is the fork's key structural
   advantage; it needs a GGUF draft head plus a draft-vocabulary map.
4. **Raise acceptance.** At acceptance 2.6, every extra accepted token is nearly
   free (the step is fixed-cost). A better draft head (distilled) or
   probabilistic draft proposals for sampled traffic (`min(1, p/q)` acceptance
   instead of exact match) are the two routes; both are spec-loop/model work.
5. **Fuse the small ops in the verify pass**: `concat_non_cont` (1.14 ms),
   `quantize_q8_1` (0.88 ms), `rms_norm` (1.03 ms), `cpy_scalar`/`k_bin_bcast`/
   `k_get_rows` (~1 ms). ~4 ms of the 49.6 ms pass, plus the ~5 ms of launch
   gaps that 38 kernels per layer produce.
6. **A ~4.25 bpw body quant** to cut the 15.3 GiB per pass (needs the F16 source
   to requantize; the UD-Q4_K_M mix is already quality-optimized).

Lower priority now: the vec kernel's q4_0 KQ dot (the 262k profile's single-token
path), which the measurements put at ~17 ms of a 262k-prompt step.

## Measured clamps

- `--spec-type draft-mtp` depth: 2 without a confidence gate; 6 with
  `--spec-draft-p-min 0.75` is the best upstream chat config (56.0 tok/s at 8k
  wikitext, sampled acceptance 3.27).
- DFlash2 `--spec-draft-n-max 7`: drafter pass ~65 ms on sm75 in both
  runtimes; not viable.
- KVarN (`kvarn5/kvarn4`, 1024-token tail) at 32k: decode within noise of
  q4_0; it is a quality/context tool, not a speed one.
- UD-IQ4_XS: no step-time gain over UD-Q4_K_M on sm75.
- ik_llama.cpp (`7cff686d`) + ubergarm `MTP-IQ4_KS`, q8_0 KV,
  `--merge-qkv -muge --ctx-checkpoints 0`: 57.7 tok/s at 8k and 40.9 at 32k
  wikitext with MTP4, and 105.2/60.0 with the `ngram-mod` + MTP chain. Without
  `--ctx-checkpoints 0` the 32k prefill dies allocating ~150 MiB per
  checkpoint. ik's `/metrics` exposes no spec-decode counters in this build.

## Evidence location

Runtime, models, and raw logs are operational evidence on tiberius under
`/data/llamacpp-parity/`, not repository content:

- `/data/llamacpp-parity/run/`: the arm drivers (`arm4.sh`, `arm-ik.sh`),
  the ik CUDA build script, and the per-arm server logs.
- `/data/llamacpp-parity/models/`: UD-Q4_K_M (also on `/persist`), UD-IQ4_XS,
  the MTP sidecar, DFlash2 Q4_K_M, and ubergarm `MTP-IQ4_KS`.
- `/data/llamacpp-parity/src/ik_llama.cpp`: the tested ik build
  (`7cff686d`, CUDA 12.9, sm75).

The archive mining came from pius's r/LocalLLaMA mirror
(`/persist/reddit-mirror/localllama`, 126k posts / 2M comments, snapshot
2026-08-31); the threads that mattered are the 16 GB-VRAM tuning study
(`1vrchn9`), the ik/beellama/upstream backend comparison (`1tgis7s`), the
spec-decoding bench (`1ujo46r`), the DFlash2 threads (`1vsuaoj`, `1vsy4l2`),
and the BeeLlama announcements (`1t88zvv`, `1tkpz2y`).

Packaged artifacts:

- `pkgs/llama-cpp-cuda.nix`: mainline b11050 CUDA release for sm75.
- `pkgs/beellama-cuda.nix`: beellama v0.4.6.
- `patches/llama-cpp-native-q4-dequant.patch`: the native q4_0/q8_0 dequant
  kernel/loader patch, to be applied in a source build on top of b11050 (a
  prebuilt release cannot be patched after the fact).
- `patches/llama-cpp-sm75-prefill-fa.patch`: the sm75 prefill attention tile
  fix (ncols2=1 for gqa_ratio>4) plus the prefill-shaped FA correctness cases;
  +4% prefill at 32k and +12% at 128k on the production model.
- `patches/llama-cpp-sm75-mmvq-batch.patch`: the Turing MMVQ rows-per-block /
  warp tuning for batches 2-8 (+10-24% at n=3, +19-21% at n=5), which is what
  makes MTP4 viable (54.4 tok/s at 64k/32k against MTP2's 47.0).
- `pkgs/qwen38-sm75/gguf-tools/`: `gguf-dump-tensor.py` (extract one tensor's
  raw bytes), `requant.c` (requantize a tensor with ggml's reference kernels)
  and `gguf-add-tensor.py` (add one raw tensor to a GGUF, copying metadata and
  existing tensors verbatim). Used to build the fast-draft model below.
- **Fast-draft head model**: the qwen35 MTP graph prefers
  `blk.N.nextn.shared_head_head.weight` over the shared `model.output` when the
  GGUF provides it, so a cheaper draft head needs no code changes. Requantizing
  the head from Q6_K to Q4_K (994 -> 682 MiB) gives **+7% decode with identical
  acceptance** on MTP4; Q3_K is *slower* despite fewer bytes (heavier dequant).
  The modified model lives on tiberius as
  `Qwen3.8-27B-UD-Q4_K_M-fastdraft.gguf`; the head only affects which tokens are
  *proposed*, so output quality is unchanged (retrieval and GSM8K gates pass).
- `pkgs/qwen38-sm75/bench-llama.py`: llama-server bench counterpart of
  `bench-one.py` (acceptance, decode, cold prefill via `--nonce`).
- `qwen38-sm75-bench-llama` wrapper, installed with the qwen38-sm75 package.

### Decode FA kernel (in progress)

The remaining decode bottleneck is the generic MMA FA kernel: 1.42 ms per call
at a 64k context, about 36% of decode GPU time, and ~11x off its DRAM bound
(ncu: 12.5% occupancy, 0.12 issued warps/scheduler, 52% long-scoreboard stalls,
mem 9.4%). Its decomposition (one block per query-row tile x KV tile, one
partition pass per block) re-reads the KV cache and cannot hide the latency of
wide 256-dim loads. The replacement is a flash-decoding style split-KV kernel:

- grid `(n_chunks, n_kvh)`; a block owns **all query heads of one KV head** and
  one contiguous KV chunk, so K/V bytes are read exactly once per layer;
- rows = `gqa * n_q` (<= 32, i.e. `n_q <= 5` at gqa 6), 256 threads;
- per 64-key tile: QK over 4x4 thread tiles, online softmax with row stats
  reduced over 16-lane groups via shuffles, PV over 4x8 thread tiles
  (32 accumulator registers per thread);
- typed KV loads: f16 / q8_0 / q4_0 dequantized in the tile load, which also
  removes the f16 pre-conversion pass the generic kernel pays for quantized KV;
- per-chunk partials (acc, max, sum) plus a small combine kernel.

Status: the kernels live in `ggml/src/ggml-cuda/fattn-decode-kernels.cuh` (kept
free of ggml headers so a standalone harness can build them in ~30 s) with the
host glue in `fattn-decode.{cu,cuh}` on tiberius, gated behind `GGML_FA_DECODE=1`;
the default path is unchanged. **Correctness is green**: 1366 of the
test-backend-ops FLASH_ATTN_EXT cases pass with the kernel enabled (f16/q8_0/q4_0
K and V, masked and unmasked, nb=1/3, kv up to 1024), and a standalone harness
(`/data/llamacpp-parity/src-decode/test_fa_decode.cu`, double-precision CPU
reference, per-row error report) passes f16/q8_0/q4_0 with causal masks, ragged
and multi-chunk KV, and production shapes (n_q=5, gqa=6) at ~1e-5 error.

**Performance is the open problem: the kernel is ~1.9x slower end-to-end**, not
faster - 53.0 -> 27.9 tok/s decode at a 64k context (fastdraft + MTP4 + ub 512),
i.e. roughly 5.8 ms vs 1.4 ms per attention layer. The decomposition is not the
problem (it is now validated); the inner loops are: they are fp32 FMA with 4x4
(QK) and 4x8 (PV) per-thread tiles, which is ~2 FMAs per shared-memory float and
therefore pinned near half the fp32 FMA rate, while the generic kernel runs the
QK on Turing tensor cores. The fp32 FMA peak (~26 TFLOP/s aggregate) is also
about half the fp16 tensor-core peak (53.8 TFLOP/s) even at 100% efficiency, so
no amount of SIMT tuning reaches the generic kernel. The next step is therefore
to keep this decomposition and combine pass but move QK and PV to
`mma.m16n8k16` (emulated on Turing by 2x `m8n8k8`) with f16 fragments via
ldmatrix - the DRAM floor at 64k is ~128 us/layer, so the headroom is large.

Two related measurements bound what is achievable in this area, both taken at a
64k context with the fastdraft model + MTP4 + ub 512:

- Forcing `GGML_FA_NCOLS2` (the generic MMA kernel's KV-split-across-blocks knob,
  normally restricted to prefill; the guard was relaxed locally to make it
  reachable from decode) gives 39.7 / 48.8 / 51.3 / 51.5 tok/s for
  ncols2 = 1 / 2 / 4 / 8. So parallelism in the KV direction is worth ~+30% over
  a forced ncols2=1, but **the default decode selection (53.0 tok/s) is already as
  good as the best forced split** - the generic kernel is not simply short of
  blocks. Correctness of the split path was verified for these shapes (145/145 on
  the mask + f16/q4_0/q8_0 subset; its 120 failures under a blanket override are
  ALiBi/sinks cases that the normal selector never routes there).
- Therefore neither more blocks (this) nor a bandwidth-structured SIMT kernel
  (above) beats the existing kernel as-is; the remaining path is to keep the
  validated split-KV decomposition and move its inner loops to tensor cores.

### Tensor-core inner loops: correct, 3.4-5.4x over SIMT, still 12% off the generic kernel

The QK and PV now run on tensor cores (`mma.m16n8k16` emulated as 2x `m16n8k8` on
Turing) with f16 fragments from shared memory, on top of the validated split-KV
decomposition. **Correctness is green**: 1,160 test-backend-ops FLASH_ATTN_EXT
cases pass with the kernel enabled, and the standalone harness passes f16/q8_0/q4_0
with causal masks, ragged and multi-chunk KV and production shapes at ~2-6e-5
error. The harness's own layout probe (`probe_layout`) and a new usage probe
(`probe_qk`, which drives the kernel's exact `load_a`/`load_b` sequence and checks
the score tile against a CPU reference) both pass, which is what separated "wrong
fragments" from "wrong bookkeeping" during debugging.

Two real bugs were found and fixed in this step, both of the same kind and worth
remembering: the mma kernels are written against `threadIdx.x` being the warp
lane (the ldmatrix helpers depend on it), but the block was launched 1D, so
`lane = threadIdx.x % 32` / `wid = threadIdx.x / 32` silently mis-addressed every
fragment load; and the shared tile-staging helper plus the shared-memory clearing
loops indexed with `threadIdx.x` while stepping by the *block* size, which staged
and cleared only the first 32 of every 256 elements. The fix is to launch
`(32, nwarps)`, take `lane = threadIdx.x`, `wid = threadIdx.y`, and use a flat
`wid*32 + lane` for bulk loops.

Harness timing, same data and same (single-chunk) configuration:

| KV length | SIMT | mma |
|---|---|---|
| 512   | 708 us  | 208 us |
| 4096  | 5519 us | 1456 us |
| 16384 | 22019 us | 4057 us |

End to end at a 64k context (fastdraft + MTP4 + ub 512, decode tok/s):
baseline **53.0**, SIMT kernel **27.9**, mma kernel **46.8**. So the tensor-core
port recovered most of the deficit but is still 12% slower than the generic MMA
kernel rather than faster.

The remaining 12% has an identified cause: the per-tile structure is fully
serialized. Each 64-key tile does stage-K, sync, QK, sync, softmax, sync, stage-V,
sync, fold+PV, sync - five barriers and no overlap, so the kernel pays staging
*plus* compute instead of max(staging, compute); staging alone is the DRAM bound
(~293 us/layer at 64k). The fix is double-buffered K/V staging with cp.async.
That does not fit at TK=64 (two 32 KB buffers plus Q 16 KB plus P 8 KB exceeds the
64 KB budget), so it wants TK=32: 2x16 KB + 16 KB + 4 KB = 52 KB.

### Tried and rejected: register-staged software pipelining

A software-pipelined variant was implemented and measured (each warp holding its
share of the next K/V tile in registers, loads issued during the QK/PV so their
latency overlaps compute, with K and V staging split so the V publish no longer
blocks the QK; 4 barriers per tile instead of 5). It is *correct* (errors
unchanged) but 1.7-2.3x **slower**: 208 -> 349 us at 512 keys, 1456 -> 2992 us at
4096, 4057 -> 9259 us at 16384. ptxas explains it: the kernel went from a normal
budget to **255 registers with stack spills** (264-408 bytes of stack), because
the PV accumulators, the mma fragments and 64 prefetch registers do not fit
together. The scalar 16-bit register path also replaces the vectorized
cooperative block staging. So on Turing (which has no `cp.async`) register
staging is a dead end for this kernel, and the smem-double-buffer route is ruled
out at D=256/TK=64 by the 64 KB / SM budget (it would need ~128 KB). Reverted;
the best mma variant remains 206 us / 1442 us.

Consequence for planning: the FA is ~22 ms of a ~79 ms step at 64k, and the
remaining FA headroom is real but expensive (the DRAM floor is ~4.7 ms/step,
i.e. ~7x below the current kernel, and reaching it needs a different staging
architecture, not tuning).

### Same-day engine comparison (re-anchored) and what it implies

Both engines were measured through the *same* script (`bench-warm.py`: send the
prompt twice, the second call hits either engine's prefix cache, so the wall time
is decode), the same wikitext prompts, and greedy sampling:

| engine | 31.7k prompt | 61.7k prompt |
|---|---|---|
| vLLM fork (int4 KV, MTP4) | 84.3 tok/s | 51.3 tok/s |
| llama.cpp (fastdraft + MTP4, f16/q8_0 K, q4_0 V) | 46.4 tok/s | 28.8 tok/s |
| gap | 1.82x | 1.78x |

That is materially worse than the ~1.4x the campaign-era numbers implied, and it
changes the plan. At 61.7k the fork's step is ~82 ms and llama.cpp's is ~146 ms
(with ~4.2 accepted tokens per MTP4 step), i.e. ~64 ms too slow - but the
components add up to only ~78-85 ms (weights 34-40, FA ~21, elementwise ~5,
draft ~14, sampler ~2). So roughly 60 ms is unaccounted for, and the obvious
suspect is every cost that scales with the *batch* rather than with weight bytes:
elementwise work (~5 ms at n=1 becomes ~23 ms at n=5), the GDN/SSM layers, and
the per-step bookkeeping.

The existing nsys breakdown below was taken at n=1 (llama-bench), which
understates exactly those terms. **So the next measurement is a profile of the
MTP4 verify step (n=5), not of single-token decode.** Until that is done, the FA
(-12%, opt-in) and MMVQ (~2-5%) work addresses only a small part of a 1.8x gap.

### Decode profile at the real MTP batch sizes (complete capture)

nsys kept dropping kernels until the run was shortened to 60 generated tokens with
`--sample=none --cpuctxsw=none --cuda-flush-interval=0`; then the capture is
complete and the shares are trustworthy:

| share | kernel |
|---|---|
| ~24% | `mul_mat_vec_q` at **n=5** (types 13/23/12) |
| ~25% | `mul_mat_vec_q` at **n=2, 3 and 4** (types 13/23, ~10 ms each) |
| ~17% | `mul_mat_q` (MMQ, 32-row tiles) - the 32-token *prefill* of both calls, not decode |
| 3.9% | `gated_delta_net_cuda` |
| ~5% | elementwise/glue (concat 2%, quantize 1%, rms_norm 1%, silu, cpy, add) |

The key fact is that the MTP path runs the weight matmuls at **n = 2, 3, 4 and 5**,
not just at n=5, so **~45-50% of the entire decode is small-n MMVQ** - precisely
the regime where the earlier measurement showed it collapsing (n=5: 387 GB/s of a
587 GB/s practical peak, n=8: 230). That is the single dominant target, and it is
why the campaign note said the real fix for it is "smem-staged weights, int8
tensor-core tiles for n<=8" rather than more tuning of the current structure.

### GDN is at its DRAM floor (bounded item, closed)

The GDN kernel is 3.9% of decode and looked like the biggest bounded item. It is
not slack: the recurrent state is S_v^2 floats per value head (128x128x4 B =
64 KB), with 48 value heads per layer and 48 GDN layers, and it is read and
written once per token => 295 MB of state traffic per token. At the 587 GB/s
practical peak that is 502 us/token, against 536 us/token measured (32.2 ms over
60 generated tokens) - i.e. ~94% of the DRAM bound. The only lever is the state
dtype, and the fork's production config already uses `mamba-cache-dtype float16`
(half the traffic). llama.cpp does not expose the SSM state dtype, so matching it
is a small code change worth ~1 ms/step, gated on accuracy.

Remaining slack therefore sits in the elementwise category (~8%, individual
kernels 0.5-1 ms/step each): fuse `rms_norm` -> `quantize_q8_1` (llama.cpp only
fuses rms_norm+mul+rope today), and the cpy/concat/add glue.

### MMVQ vs MMQ crossover, and why the tensor-core rewrite is off the table

Measured MMVQ (dp4a) against MMQ (int8 tensor cores, which on Turing use
`m8n8k16` - `m16n8k16.s8` needs sm_80) on the production decode shapes at
m=17408, k=5120:

| type | n=5 MMVQ | n=5 MMQ | n=8 MMVQ | n=8 MMQ |
|---|---|---|---|---|
| q4_K | 133.1 | 154.7 | 221.0 | **153.4** |
| q5_K | 142.6 | 163.2 | 225.2 | **163.3** |
| q6_K | 165.7 | 176.1 | 226.9 | **176.5** |
| iq4_xs | 107.3 | 118.5 | 136.5 | **118.6** |
| q8_0 / q4_0 | unchanged | | | |

Two conclusions, both acted on or recorded:

- The crossover is between n=5 and n=8, so the Turing MMVQ threshold is now 5
  instead of 8 (commit `6e6690e`), giving 13-31% at n=6..8. It does not change
  the current MTP4 config, whose batches are 2..5, but it is what the data
  supports and it fixes MTP6/MTP8-style runs.
- **At n=5 MMQ is slower than MMVQ despite using tensor cores.** So a
  tensor-core small-n matmul would not fix the small-batch decode cost: at these
  batch sizes the limit is dequant ALU plus L1 traffic (ncu: L1 74%, 158
  registers, 35% occupancy), not dot throughput. That is also consistent with the
  three structural MMVQ experiments that measured negative. The MMVQ area is
  therefore considered explored, not merely un-optimised.

### Hypotheses measured and rejected (so they are not retried)

Each of these looked structurally compelling and each was measured, not argued:

| hypothesis | result |
|---|---|
| FA: register-staged software pipelining of K/V | correct but 1.7-2.3x **slower** (255 regs, spills) |
| FA: smem double-buffering at TK=64 | impossible, needs ~128 KB vs 64 KB/SM |
| MMVQ: loop-nest swap so per-row unpacking hoists | neutral (+/-3% on 7 types) |
| MMVQ: fewer rows / less unrolling for occupancy | rows=2 costs +22-25%; `unroll 1` costs +230-880% |
| MMVQ: weight reuse (unpack once, dot all columns) | +5% at n=5, -13% at n=1 in a clean prototype |
| tensor-core small-n matmul (route n=5 to MMQ, int8 `m8n8k16`) | MMQ is **slower** than dp4a MMVQ at n=5 |
| CUDA graphs for the decode path (fork uses `FULL_AND_PIECEWISE`) | zero effect: 46.52 / 46.65 / 46.52 tok/s |
| q4_0 K instead of f16 K | 10% **slower** at 64k |

What did convert: MMVQ rows_per_block made type-aware (iq4_xs +6% at n=5), the
MMVQ->MMQ threshold moved to n=5 (13-31% at n=6..8), and the earlier campaign
wins (MTP4, fastdraft head, Turing MMVQ batch tuning, native q4_0/q8_0 dequant in
FA, the sm75 prefill FA tile fix).

Verdict on the remaining gap: at ~1.8x it is **not** explained by any single lever
that could be found and tested here - eight structural ideas have now measured
negative. The fork's advantage is a sum of systemic differences (W4A16 weights
read by better kernels, fused rms_norm/silu, int4 KV with a fast attention path,
its own scheduler), each worth a few percent. Measured kernel headroom does
exist - the FA at 64k runs ~4.7x off its DRAM bound and small-n MMVQ at ~66% of
practical bandwidth - but capturing it has resisted every incremental approach
tried, which points at engineering depth in the kernels rather than a missing
idea. Beating the fork therefore needs a purpose-built engine for this exact
geometry, not more tuning of generic llama.cpp kernels.

Also settled, by ablation rather than by argument: MTP2 recovers 96% of MTP4
(45.0 vs 46.7 tok/s), `q4_0` K is 10% *slower* than f16 K at 64k (so the KV
precision is not a lever), and the elementwise/glue term is ~5%, not the ~25% an
extrapolation from the n=1 profile suggested.

### Measured decode breakdown (nsys, decode-dominated)

Profiling a decode-dominated run (`llama-bench -p 512 -n 128 -d 8192`, nsys
`cuda_gpu_kern_sum`, so absolutes are inflated by profiling overhead - read the
shares) gives a quite different picture from the older component estimates:

| share | kernels |
|---|---|
| **69%** | `mul_mat_q` over all weight types (ids 23/13/12/11/14/20/21) |
| 9% | `gated_delta_net_cuda` (the 48 GDN layers) |
| 5% | `flash_attn_ext_f16` (at 8k depth; this is the part that scales with context, ~28% of a 64k step) |
| ~8% | elementwise/glue: gated silu 2%, `quantize_mmq_q8_1` 2%, `k_bin_bcast` 1%, `concat_non_cont` 1%, `ssm_conv_long_token_f32` 1%, `rms_norm_f32` 0.7% |

So the step is dominated by weight matmuls, and the elementwise opportunity is
~8% (not ~16% as previously assumed), i.e. a good fusion pass buys ~3-4%.

The largest single tractable inefficiency is inside that 69%: the campaign
measured MMVQ at **484-552 GB/s for n=1 but only 364-456 GB/s for n=5** against a
587 GB/s practical peak - and n=5 is exactly the MTP4 verify shape, i.e. where the
decode matmul time is spent. An ncu profile at n=5 showed DRAM at 59.6%, L2 hit
41%, occupancy 34.8% and issue every 5.0 cycles - no saturated unit, so it is
latency-bound rather than throughput-bound. Bringing n=5 to the n=1 level is
worth roughly 8 ms/step (+10% decode).

Ranked levers from here: (1) MMVQ bandwidth at n=5; (2) FA at long context (needs
the staging redesign above); (3) GDN/SSM kernels (~10%); (4) elementwise fusion
(~3-4%); (5) draft chain. The fork's ~39% lead at 64k is the sum of these.

### MMVQ at n=5: mechanism found

Perf cases for the production decode shapes at n=1/5/8 were added to
`make_test_cases_perf` (the perf list previously started at n=512), which makes
this measurable. At m=17408, k=5120 with q4_K weights (50.1 MB):

| n | time | weight bandwidth |
|---|---|---|
| 1 | 93.1 us | 538 GB/s (92% of the 587 GB/s practical peak) |
| 5 | 129.9 us | 386 GB/s (66%) |
| 8 | 218.5 us | 229 GB/s (39%) |

Same weight bytes in every case, so the loss is not traffic. The mechanism is in
the inner loop: for each k-iteration the kernel calls `vec_dot_q_cuda` once per
(column, row) pair, so the *weight blocks are re-read once per column* - 5x at
n=5 - and ncu agrees that nothing is saturated (DRAM 59.6%, issue every 5.0
cycles), i.e. it is latency/issue bound rather than bandwidth bound.

Cheap lever tried and banked: `rows_per_block` is now type-aware. 8 rows at n=5
gives iq4_xs 411 -> 440 GB/s but q4_K 386 -> 361, q5_K 356 -> 340, q6_K
304 -> 282, so 8 rows is used only for iq4_xs (~29% of this model's layers).

The real fix is register-level reuse: dequantize a weight block into registers
once and dot it against all n columns, which needs a per-type "dequant to
registers + multi-column dot" path (q4_K/q5_K/q6_K plus the i-quants). That is
the single largest identified win left - the matmuls are 69% of the decode step
and they run at 66% of the achievable rate at the MTP4 verify shape.

**Confirmed the mechanism by type.** Adding a simple-dequant type to the same
measurement separates "dequant ALU" from "loop structure", because q8_0's vec_dot
is a plain int8 dot with no bit unpacking:

| type | n=1 GB/s | n=5 GB/s | n=8 GB/s |
|---|---|---|---|
| q4_K   | 539 | 387 | 230 |
| q5_K   | 552 | 435 | 276 |
| q6_K   | 541 | 444 | 326 |
| iq4_xs | 529 | 434 | 344 |
| q4_0   | 548 | 476 | 348 |
| q8_0   | 565 | **536** | **494** |

q8_0 barely degrades while every type with bit unpacking collapses, so the n>1
loss is dequant ALU / issue, not memory. The instruction accounting per 8
weights in the q4_K inner loop (`vec_dot_q4_K_q8_1_impl_vmmq`) is: ~4 ops of
nibble extraction, 2 `dp4a` for the weight dot, and 2 `dp4a` for the *sum of u* -
and the sum-of-u term does not depend on the weights at all, while the nibble
extraction is per weight block. Both are recomputed for every (column, row) pair,
i.e. ~20x at ncols=5, rows=4.

**ncu settles where the loss is.** Profiling the q4_K case at m=17408, k=5120
with an n=1 control:

| metric | n=1 | n=5 |
|---|---|---|
| registers/thread | 60 | 158 |
| achieved occupancy | 94% | 35% |
| L1 throughput | 90% | 74% |
| DRAM throughput | 79% | 50% |
| sm throughput | 56% | 58% |
| dominant stall | `lg_throttle` 5.45 | `long_scoreboard` 0.87 |

Neither shape is DRAM-bound: both are **L1 / load-store throttle bound** (90% and
74% of L1 peak), and n=5 adds heavy register pressure (158 regs -> 35%
occupancy). So the lever is *fewer L1 transactions per weight byte*, which is
exactly the weight-reuse design, not more rows or fewer. Consistent with that,
sweeping rows_per_block down is a dead end: at n=5, rows=2 costs +25% for q4_K,
+24% q5_K, +22% q6_K against rows=4 (iq4_xs is flat, and it uses 8). The
campaign's rows=4 is the optimum, and the register-pressure angle is closed.

**Three structural hypotheses were tested and all three failed to convert**, which
is the most useful result here:

1. Loop-nest swap `(k -> column -> row)` to `(k -> row -> column)` so the per-row
   unpacking could be hoisted out of the column loop: neutral, +/-3% on all types.
2. Register-pressure reduction via `rows_per_block`: n=5 rows=2 costs +22-25% on
   the k-quants; rows=4 (the campaign value) is the optimum. Reducing unrolling
   instead (`#pragma unroll 1` on both inner loops) is catastrophic - +230% to
   +880% at n>=5, neutral at n=1 - because the unrolling is what supplies the ILP
   that hides L1 latency, and the 158 registers are its price.
3. Weight reuse (unpack each weight chunk once per row, dot it against every
   column), which the L1 finding motivates: in a standalone benchmark
   (`src-decode/bench_q4k_reuse.cu`, same math and data, per-column vs reuse) it
   gives only +5% at n=5 and +14% at n=8, and loses 13% at n=1. So the L1 traffic
   reduction does not convert at the predicted size and the full rewrite is not
   justified.

Conclusion for MMVQ: within this kernel structure the n=5 case is close to what
it can deliver - the config space is at its optimum, the ILP/register tradeoff is
already balanced, and the reuse angle is worth ~5%, not 50%. Getting materially
more needs a different formulation: the natural one is a tensor-core small-n
matmul for the k-quants (dequant into mma fragments, use each fragment for all
n columns), which is exactly the machinery the FA decode kernel already exercises
(m16n8k16 via 2x m16n8k8, verified by probe_layout). That is a project rather
than a tuning pass.

A cheap hypothesis was tested first and rejected: swapping the kernel's inner loop
nest from (k -> column -> row) to (k -> row -> column), on the theory that the
nibble extraction and scale decoding are invariant across columns for a fixed row
and the compiler could hoist them. Measured: neutral, within +/-3% noise on all
seven types (q4_K n=5 129.5 -> 128.5 us, q8_0 n=5 176.8 -> 176.7 us). So the
redundancy is not where that model put it, and the next step is an ncu profile of
the marginal case (q4_K, n=5, m=17408, k=5120) to see whether it is instruction
issue, load latency or L1 throughput before any restructuring is attempted. The
swap was reverted; the tree keeps only the measured wins.

Concrete fix (design settled, not yet implemented): restructure the inner loop
nest from (k -> column -> row) to (k -> sub-block -> row -> column) with
- the 32 weights of a sub-block unpacked **once per (row, sub-block)** into 8
  int32 registers, then dotted against every column, and
- the per-(column, sub-block) sum-of-u hoisted out of the row loop (it is one int
  per (column, sub-block), so 5 registers at ncols=5).
Together that removes roughly 45% of the inner-loop instructions: at m=17408,
k=5120 the q4_K n=5 case should go from 387 GB/s toward ~550 GB/s, i.e. ~+40% on
a 69% share, or ~+25% decode. The natural place is a `if constexpr` reuse path
inside the existing kernel for the k-quant types at ncols_dst >= 2, so no other
path is touched and the existing MUL_MAT correctness suite still covers it. It
needs each type's vec_dot wrapper split into an "unpack" and a "dot with
precomputed u-sums" half.

Current end-to-end standing at 64k with MTP4 (same script, same config): generic
kernel 52.5 tok/s, split-KV mma kernel 46.4 tok/s (opt-in, off by default).

Two related measurements bound what is achievable in this area, both taken at a
64k context with the fastdraft model + MTP4 + ub 512:

- Forcing `GGML_FA_NCOLS2` (the generic MMA kernel's KV-split-across-blocks knob,
  normally restricted to prefill; the guard was relaxed locally to make it
  reachable from decode) gives 39.7 / 48.8 / 51.3 / 51.5 tok/s for
  ncols2 = 1 / 2 / 4 / 8. So parallelism in the KV direction is worth ~+30% over
  a forced ncols2=1, but **the default decode selection (53.0 tok/s) is already as
  good as the best forced split** - the generic kernel is not simply short of
  blocks. Correctness of the split path was verified for these shapes (145/145 on
  the mask + f16/q4_0/q8_0 subset; its 120 failures under a blanket override are
  ALiBi/sinks cases that the normal selector never routes there).
- Therefore neither more blocks (this) nor a bandwidth-structured SIMT kernel
  (above) beats the existing kernel as-is; the remaining path is to keep the
  validated split-KV decomposition and move its inner loops to tensor cores.

### Tensor-core inner loops (in progress)

A second harness in `/data/llamacpp-parity/src-decode/` (same kernels header, plus
`test_fa_decode.cu` running a SIMT and an mma variant of the partial kernel on
identical inputs and reporting both errors and us/call) carries this work. There,
**the mma building blocks are verified**: `probe_layout` checks the hand-written
fragment loaders and the Turing `m16n8k8`-pair emulation against a reference and
prints `PROBE PASS`, so `load_a` (A from a row-major [16][16] tile), `load_b` (B
from [8][16] = [N][K]), `load_bt` (B for the PV, read transposed out of a
[key][dim] tile) and `fa_mma::mma` are all correct.

What is not yet correct is the mma *partial kernel* that uses them: it differs
from the SIMT kernel it is compared against by ~0.1 (tolerance 1e-3) on every
row, i.e. a systematic bookkeeping error rather than a fragment error. The next
step is to bisect its stages against the SIMT kernel - the cheapest probe is to
diff the per-row `(max, sum)` partials (both kernels write them to `dMax`/`dSum`
in the harness), which separates "QK + softmax" from "PV + fold" in one run; P is
stored to shared memory as f16 from the score fragments and then read by the PV,
which makes that mapping and the tile-fold scales the prime suspects.
Timing is already instrumented in the harness (SIMT: ~94 us/call at R=12,
kv=64), so the moment the mma variant passes it can be measured against the
53.0 tok/s end-to-end baseline directly.

The stage bisect has now been run: with the per-row `(max, sum)` partials of both
kernels diffed, the mma kernel's **QK + softmax** stage is the wrong one (PV/fold
is downstream and not yet implicated). At R=12, kv=64, no mask, the mma kernel's
tile row max comes out *smaller* than the SIMT kernel's (0.63 vs 1.17) while its
row sum comes out *larger* (33.8 vs 21.2) - i.e. its scores are systematically
flatter, which is what a dot product that only accumulates part of the K
dimension looks like. Two candidate explanations remain: the A/B k-halves in the
per-tile loop, or the score-fragment -> shared-memory store mapping. A dedicated
usage probe (`src-decode/probe_qk.cu`, drives the kernel's exact `load_a`/`load_b`
sequence for A = K tile and B = Q tile and compares the resulting 16x8 score tile
against a CPU reference) was added for this, but its comparison/report loop is
buggy - it printed `worst diff 0` together with an invalid index - so it must be
fixed before its result means anything. Note the separate `probe_layout` binary
does pass, so the primitives themselves (loaders plus the Turing m16n8k8-pair
emulation) are correct and the fault is in this kernel's use of them.

Facts discovered while wiring it up (useful for any future attention work):

- **The FA output layout is `[D, n_head, n_q]`** - heads on axis 1 and query
  tokens on axis 2, the opposite of Q's `[D, n_q, n_head]`. Writing it the Q way
  produces a 2.25 MB out-of-bounds store, far from any allocation.
- The FA mask is additive with **keys on the fast axis**:
  `mask[key + q * (nb[1]/sizeof(half))]`.
- Quantized KV rows are packed, not padded: for q4_0 at D=256 the row stride is
  `144` bytes (`256/32 * 18`), while the same cache's f16 rows are `512`.
- The FA mask is additive and clamped at +/-1e30 in the kernel, so the "+inf"
  mask blocks that the reference suite generates behave as "max weight" instead
  of producing NaN via inf - inf.
- Kernel-side bug worth remembering: the online-softmax reference max must be
  shared by every thread that contributes to a row. Using a thread's own running
  max while the tile exponentials used a different max is invisible for a single
  KV tile (the normalization cancels) and for <= 4 rows, but leaks a ~1% scaling
  error across tiles otherwise. The fix is to make the tile max tile-local and
  pass an explicit per-tile scale (plus a rebase factor) to the PV threads.
- compute-sanitizer is available via
  `nix shell --impure nixpkgs#cudaPackages.cuda_sanitizer_api`; it pins the
  faulting kernel, block/thread and the offending address in one run and was
  what located the output-layout bug.
