# DeepSeek-V4.1-Flash IQ1_M on tiberius — feasibility model before the download

Status: **model complete; nothing deleted or downloaded.** Written 2026-10-24 after the
sm_75 `strata-dsv41` build and the IQ1_M kernel tests. Labels: **[M]** measured,
**[D]** derived, **[E]** estimate.

## 1. What is already proven on the box

- `strata-dsv41` builds for sm_75 from the v0.2.4.2 source (Nix, on tiberius) and
  `ds4_iq_test` passes **IQ1_M** token/set/CPU rows on the 2080 Ti: `ALL OK`.
  `ds4_slot_test` passes; `ds4_gg_bench --type 29 --expert` is bit-identical across
  ggml/auto/own. The GPU-family blocker is gone for a self-built engine; the official
  `strata-dsv41` package still has no sm_75 package.
- CPU lane, 11 threads, IQ1_M: **17.6–18.2 GB/s** (`--expert`), plain read 18.6 GB/s.
  The CPU lane is memory-bound and **not** the wall. The earlier 2.0 GB/s reading was
  the 3.07 GB default working set under memory pressure; the 512 MB run is the lane
  rate, and the native IQ1_M rows are bit-identical to the Strata rows. No port to
  `own_rows` is needed.
- Optane: 6.88 GB/s CPU mmap random blobs; 6.57–6.87 GB/s registered H2D; pageable
  2.3–2.4; PCIe from DRAM 12.2 [M, prior campaign].
- The shipped profile `data/dsv41/profile-2.00.bin` has 43 layers × 384 uint32; the
  first 40 layers rank the experts. **Top 60 per layer (the 2,409 VRAM slots) cover
  41.3% of the routing mass** (mean; 32.1–46.0% across layers). Top 90 = 51.9%,
  top 120 = 60.9%, top 180 = 75.4%, top 240 = 86.3%. This is the conservative static
  hit-rate anchor; the adaptive cache and the conversation locality can raise it.

## 2. The arithmetic

- Expert blob: 114.56 GB / 15,360 = **7.46 MB**; active per token 6 × 40 = 240.
- Active bytes/token `B = 1.790 GB`.
- `decode tok/s = 6.8 / (B × (1 − h))` if the miss stream is Optane-bound; the CPU
  lane at 18 GB/s only binds below ~2.7 tok/s, so the disk is the wall.
- VRAM: 2,409 experts = 60/layer = **15.6% slots** (18 GB); with a 22 GiB card the
  real number after dense 6.16 GB and reserve 600 MiB is closer to 2,265 slots
  (16.9 GB), and a 4096 prefill chunk costs ~110 slots more.
- RAM: the engine's automatic paths are all zero on 7.4 GiB — the `kRamMargin` is a
  hard **8 GiB**, and `--ssd-cache` auto is `avail − 12 GB` (off below 4 GB). The
  store itself **does work for the official IQ1_M GGUF pack**: `pack_gguf.py` writes
  `format gguf` (`tools/dsv41/pack_gguf.py:888`), `Pack::load` sets `gguf = true`
  (`ds4_model.cu:321`), and `expert_layout_mx` leaves `lay.fmt = kFmtMXFP4` with the
  real IQ type in `lay.K[r]` (`:1666-1667`); `store_gb()`/`init_store()` therefore
  reach the store. An `iq_pack`-style native `experts.bin` pack would not (no GGUF,
  `store_gb()` returns 0); this plan uses `pack_gguf.py`. Only the floor blocks the
  store. Screen `--ssd-cache 2/3/4` with `DS4_STORE_FLOOR_GB` 0.5/1/1.5 and
  `DS4_STORE_RESERVE=32`, `DS4_STORE_PREGROW=0`, `--ssd-policy lfu`, against
  `MemAvailable`: 3 GB is ~400 experts (top ~70/layer), 4 GB ~535 (top ~73/layer).
  The static gain over VRAM-only is ~10–20% (h 0.413 → 0.45–0.47); the larger
  8–12 tok/s band needs the adaptive cache/conversation locality, not the store
  alone. The store is the only cache that works on DAX; the page cache is zero on a
  `dax=always` mount.
- Multi-turn/agent work: `STRATA_DS4_SLOT_KEEP=1` + `STRATA_DS4_SLOT_DIR` keeps the
  conversation state (~17 MB per 6.5K tokens; 4 slots ≈ 68 MB, `SLOT_GB` cap 16)
  across turns/restarts, removing the re-prefill that an agent loop otherwise pays.
  This is the DeepSeek analogue of Qwen's prompt cache and is worth much more than
  its RAM cost for the refresh job.
- `STRATA_DS4_DISK_SKIP_W` is the DeepSeek analogue of Qwen's tail skip: on decode
  windows only, leave out a routed expert whose route weight is below W and whose
  pages are not in RAM; the weight is lost (no renormalisation). It changes answers.
  `in_ram()` does **not** consult the store, so with `--ssd-cache` it misclassifies
  store-resident experts; a small patch is needed before using the skip with the
  store. Without the store, `in_ram()` on DAX is not meaningful.
- DSpark is auto-disabled on this box (`experts 114.56 GB > 1.5 × GPU room`), so its
  7.98 GB download can be skipped entirely.

## 3. Decode scenarios

`h` = total hit (VRAM + RAM); `s` = share of misses skipped by `DISK_SKIP_W`.

| scenario | h | s | misses/token | decode tok/s |
|---|---:|---:|---:|---:|
| static profile, VRAM only | 0.413 | 0 | 141 | **6.4** |
| + 3 GB store (top ~70/layer) | ~0.45 | 0 | 132 | **7.0** |
| + adaptive/conversation locality | 0.55 | 0 | 108 | **8.4** |
| same, good locality | 0.65 | 0 | 84 | **10.9** |
| same, Qwen-like locality | 0.75 | 0 | 60 | **15.2** |
| h=0.55 + skip W=0.08 (s≈0.15) | 0.55 | 0.15 | 92 | **9.9** |
| h=0.65 + skip (s≈0.25) | 0.65 | 0.25 | 63 | **14.4** |

Expected operating point: **8–12 tok/s** (6.4 pessimistic, 15 optimistic). The static
profile is only the floor: the engine **learns the prompt's routing** (`l.heat[e] +=
cnt`, `ds4_model.cu:7096`) and after a chunked prompt runs `post_prompt_swaps`
(`:5908-5947`), moving the prompt's hottest CPU-lane experts into the spare VRAM
slots before decode. The lookahead also guesses the next layer's experts. This is the
built-in lossless cache seed; a narrow conversation can therefore beat the 41.3%
profile coverage substantially. The >20 tok/s target needs h≈0.81, i.e. the prompt and
the output must share most of their hot set; the first `--verbose` run's hit/store
stats decide whether that is real. Tune `DS4_CACHE_MARGIN/BONUS/DECAY/INFLIGHT`
(lower margin/bonus = more post-prompt swaps), `DS4_CACHE_THREADS` 2–4, LFU store,
and `STRATA_DS4_SLOT_KEEP` for multi-turn heat.

For comparison, the Qwen lane runs 20–22 tok/s; DeepSeek is ~2× slower at the static
hit rate, but a 763B model at 8–15 tok/s on a 2080 Ti / 7.4 GB box is the surprising
part. The biggest unknown is the prompt-seeded hit rate, not the arithmetic.

## 4. Prefill scenarios

The single-card default chunk is **8192** (`o.tp` defaults 2, so `prompt_par` is true
even after the block split clamps `tp` to 1; `own_default` is false). The chunk
buffers are allocated before the experts and are pinned host RAM: ~1.4 GB at 4096,
~2.5 GB at 8192, ~4.5 GB at 16384. On 7.4 GiB, 16384 is not viable; 4096 is the safe
choice, 8192 the one to test.

With the prompt skip **on** (default `STRATA_DS4_PROMPT_SKIP=1`; release notes: a 16K
prompt ~34% faster, top-1 same in 99.5% of 799 positions), Optane 6.8 GB/s, and
96.56 GB of non-VRAM experts per chunk pass:

| prompt | C=4096 | C=8192 | C=16384 |
|---:|---|---|---|
| 4K | 1 pass, 79.7 GB, 11.7 s → **350** | same → **350** | same → **350** |
| 8K | 2 passes, 128 GB, 18.8 s → **435** | 1 pass, 64 GB, 9.4 s → **870 read-bound** | same → **870** |
| 17K | 3 passes, 225 GB, 33 s → **496** | 2 passes, 112 GB, 16.5 s → **992 read-bound** | 1 pass → **1,985** |

The 2080 Ti compute ceiling is ~350–650 tok/s for this prefill (2.9e10 FLOP/token at
an effective 10–20 TFLOPS); so the realistic band is **350–650 tok/s**, with
C=8192 the best if its 2.5 GB pinned buffers allocate. This is in Qwen's prefill
class at 4K (457 tok/s) and slower at 27K (Qwen ~1,000).

## 5. Disk layout and Qwen recovery

Backbone 112.43 GiB must stay on Optane (the 6.88 GB/s stream); Engram 103.00 GiB
goes to `/data` (SATA; sparse rows, ~110 KB/token, off the critical path); DSpark is
skipped. The Engram can be a symlink in the pack dir; `tensors.txt` records a path,
and the engine opens `model_dir + "/" + name`, so a symlink works. `engram.bin` (the
MB-sized hash parameters) must stay in the pack dir.

Actual safe layout used (2026-10-24): delete `/optane/strata-data` (107 G; the PLE
table goes with it), `/data/strata-models` (51 G IQ3_S shard 1; the coder shard was
already gone) and `/data/strata-staging` (1.2 G). **Keep
`/data/qwen2080-orchestration-20260906`** — its 41 GB BF16 gain-source is the only
canonical copy; a pius backup copy is optional. Result: `/optane` ≈123 GiB free
(backbone 112.43 + pack/headroom ≈ 118 → ~5 GiB spare); `/data` ≈114 GiB free
(Engram 103 + 5.6 headroom → ~11 GiB slack). Qwen recovery downloads **IQ3_S shard 1
(51.05 GiB) + PLE shard 2 (28.80 GB) + MTP (~6.5 GB) ≈ 86.3 GB**, then rebuilds the
packs in ~7 min (46.84 GiB `experts.bin` 4m31s, dense 6s, PLE copy 59s); the coder
lane adds its 29.61 GB shard 1. All deleted Qwen files are pinned and re-downloadable
from the ISTA-DASLab/Coder HF repos.

## 6. Experiment sequence (after a go)

1. Record the Qwen service health, free space, and the IQ3_S shard sha; stop
   `tiberius-strata`.
2. Delete `/optane/strata-data` and `/data/strata-models` (plus `/data/strata-staging`);
   keep `/data/qwen2080-orchestration-20260906` and its 41 GB gain-source. Verify free
   space (the actual safe layout in §5).
3. Download the four IQ1_M shards (120.72 GB) to `/optane/dsv41/model/` and the
   Engram (110.60 GB) to `/data/dsv41/engram/`; skip DSpark. Verify SHA-256.
4. `pack_gguf.py` with the final layout, `--engram` pointing at `/data`, the 5.8 MB
   Unsloth metadata shard for `--engram-meta`, and the shipped
   `data/dsv41/profile-2.00.bin` copied in as `expert-profile.bin`; run
   `strata-dsv41 --pack-info`.
5. First run:
   `--pack /optane/dsv41/pack --mmap-experts on --prefill-chunk 4096
   --ssd-cache 3 --ssd-policy lfu --cpu-threads 11 --max-context 32768
   --dspark auto --verbose`
   with `DS4_STORE_FLOOR_GB=1.5 DS4_STORE_RESERVE=32 DS4_STORE_PREGROW=0` and
   `STRATA_DS4_SLOT_KEEP=1 STRATA_DS4_SLOT_DIR=/persist/strata/ds4-slots`. Capture
   the `--verbose` `pm.disk/pm.dma/pm.cpu` rates, the accepted chunk, the store hit
   rate, the slot reuse, and `MemAvailable`. If the 4096 chunk is accepted and the
   store has slots, the model is live.
6. Tune in this order: chunk 4096 vs 8192; store 2/3/4 GB with floor 0.5/1/1.5
   (watch `MemAvailable`; the store's `store_watch` gives chunks back below 5 GB
   free); `--vram-experts`; `DS4_CACHE_*`; then `STRATA_DS4_DISK_SKIP_W` only after
   fixing `in_ram()` for the store, with a KL/top-1 check. Keep the prompt skip on
   (`=1`; `=2` only if the answers gate passes); keep DSpark off. `DS4_PF_ALL` is a
   no-op on Linux; skip it.
7. Run the hindsight refresh job on the DeepSeek lane and compare its wall time and
   page quality with the Qwen lane's 283 s. DeepSeek output is ~2× slower per token,
   so it needs fewer calls/tokens or a quality win to be worth keeping.
8. If not: re-download the PLE 28.8 GB + MTP 6.5 GB, rebuild the iq3_s pack, restore
   the Qwen service, and verify `/health` + the answer hash.

## 7. Decision

The disk fits, the engine builds and passes IQ1_M kernels on sm_75, and the arithmetic
supports **8–12 tok/s decode and 350–650 tok/s prefill** with the store, the adaptive
cache and the chunk/skip tricks — 6.4 tok/s if the profile stays static and the store
alone only adds ~10%. The remaining unknowns are the adaptive hit rate, the 7.4 GiB
RAM pressure with the chunk buffers, and the Engram on SATA. It is worth one bounded
experiment if the DeepSeek quality is the goal; it is not a speed win over Qwen.

## 8. Measured on tiberius, 2026-10-24

The lane is **functional**: four IQ1_M shards + Engram + metadata downloaded and SHA-256
verified, packed with the official recipe (no DSpark), `--pack-info` sees 40 x 384
experts / 6 active / every tensor device-supported, and the Paris smoke test passes.
`strata-dsv41` loads in ~10 s; the pack is 5 files on Optane + `/data`.

Cold benchmark, `--ids`, 64–128 generated, `--prefill-chunk 4096`, store 2 GB
requested, `DS4_STORE_FLOOR_GB=0.5`:

| cell | prompt tokens | prefill | decode |
|---|---:|---:|---:|
| 4K | 3,772 | 37.5 tok/s | 5.37 tok/s |
| 8K | 7,150 | 47.1 tok/s | 5.60 tok/s |
| 17K | 13,597 | 52.6 tok/s | 5.73 tok/s |

Diagnostics from the 4K cell: 1,871 experts in VRAM (14.28 GB; 569 MiB free), 48% hit;
123 CPU-lane experts/token; the CPU lane calibrates 6.24 GB/s from disk / 6.9 GB/s in
RAM; the prompt streamed 87.7 GB at **1.00 GB/s** (all `pread`, both O_DIRECT and
buffered), while the compute waited 19.4 s; the store allocated **0 of 229 slots**
(only 1.4–2.6 GB RAM free after the 4096 chunk buffers). The expert cache learned the
prompt and made 1,280–1,287 post-prompt swaps, which is why the hit is 48% rather than
the static profile's 36–41%.

Attempts to lift the prompt path without the DAX window: forcing buffered `pread`
(`DS4_NO_DIRECT=1`) and copying from the file mapping instead of `pread` both still
read **~1.00 GB/s**; the 6.24 GB/s figure is the CPU lane's compute-side mapping, not
a staging copy. The Qwen `STRATA_REGISTER_DAX` sliding window / direct DMA port is
required for the ~250 tok/s prefill; it is a 1–2 week engine port, not a flag.

**Verdict: 15 tok/s is not reachable on this hardware, and 20 is not close.** The
decode wall is 123 CPU-lane experts/token at ~6.5 GB/s plus Engram ~16 ms; a 15 tok/s
lane needs ~75% hit (≥11,500 experts) or ≥15 GB/s, against 1,871 VRAM slots and a
<1 GB effective RAM tier. The measured lane is **5.4–5.8 tok/s cold** (warm/slot-keep
may add a little); it is a quality experiment, not the Qwen-speed replacement. The
`STRATA_DS4_DISK_SKIP_W` path is answer-changing and could add ~10–20%, not 2×.

The pack is **mixed**: 83 expert tensors IQ1_S, 20 IQ2_XXS, 15 IQ1_M, 2 IQ2_S (the
GSQ-RCO search assigns a type per tensor). The Paris smoke passing means the dominant
IQ1_S sm_75 GPU kernel is correct, not just IQ1_M. No DSpark/MTP is in the pack.

The `--ids` timing run reports “windows of 32768”; it is not the chunked serve path.
The queue’s `Job::mem` path was tested. The compile error (`j.map` is `const void*`,
`j.mem` is `const uint8_t*`) is fixed by the cast, but the tested form
`j.mem = static_cast<const uint8_t*>(j.map)` also **overwrites the existing store/RAM
source** set at `ds4_model.cu:3391` (`j.mem = it.ram != nullptr ? it.ram + … :
nullptr`). The correct form preserves it:
`j.mem = j.mem != nullptr ? j.mem : static_cast<const uint8_t*>(j.map)` at both
`:3392` and the lookahead at `:7602` (the lookahead starts with `j.mem` null, so it
takes the map). With the store-0 4K test line 3391 is `nullptr`, so preserve/fallback
is a no-op and the first prompt still **crashes with a CUDA illegal memory access**;
the crash is independent of the overwrite. The earlier `Job::map` branch also
crashed, and forced buffered `pread` still reads 1.00 GB/s. The staging-copy
micro-patches are a dead end; the flow needs the real **DAX-window / direct-DMA
integration** (the Qwen `STRATA_REGISTER_DAX` analogue) to read at 6.24–6.8 GB/s.
That is the only remaining prefill lever, and it is a 1–2 week engine port.

The resident server (`/data/dsv41-serve.json`, port 8081) was tested with the base
engine and two identical 4K requests: first **102.5 s**, second **10.8 s** with
3,771 / 3,772 prompt tokens cached and the same answer sha; decode **5.9 tok/s**. The
prompt/slot cache is the real agent-loop win (a repeated turn is ~10× faster in
latency), but it does not change the decode rate. Extrapolating the 17K refresh:
258.6 s prefill + ~170 s for 1K output ≈ **430 s cold** against Qwen's 283 s; with
the prompt cache the output is still ~170 s, so the lane is slower per call.

Decode is **5.4–5.9 tok/s cold**; the 2 GB store adds <2% slots, and 15/20 tok/s
would need ≥75–81% hit or ≥15 GB/s. No lossless flag changes that; the lane is a
quality experiment, not the Qwen-speed replacement.

## 8b. Speculative, DAX and lookup on tiberius, 2026-10-27

**Clean baseline:** 5.80 tok/s decode on the regular pack (5.80 / 5.81 / 5.80 at
4,056 prompt tokens), prefill 38.4–40.6 tok/s. The earlier 3.58 arm was the
nondeterministic 0.9 GB hot-set preload, not a stable baseline; store flags are
neutral (5.4–5.8).

**DSpark/MTP** (the V4.1 MTP is DSpark; `pack-dspark`, 7.98 GB Unsloth Q8_0,
`mtp.0-2`, 1,242 tensors): acceptance **3.17 tokens/round** (43.9% of 440 drafts;
per position 79.5 / 59.1 / 37.5 / 26.1 / 17.0%) against a 3.3 break-even. Decode:
none 3.59, `--dspark off` (drafter resident) 4.52, on block 3 4.71, on block 0
2.51. The drafter arms are **below the clean 5.80 baseline**; drafting adds only
+4.2% inside a degraded store/VRAM state. The 8 GB drafter is a non-goal here.

**DAX prefill port** (`x0fv…`, 6912 MiB, 41 layer windows): the 2.65 GB
registration failed **out of memory**, leaving 290 experts / 2.0 GB from the
window; 4K prefill **99.6 s**, decode 5.70. A 1 GiB budget fits no 2.65–3.33 GB
layer (0 DAX bytes; 97.8 s, 5.75). The port is correct, but the host/pin budget
cannot hold a layer in this process; no prefill gain. The documented 8192 chunk
also regressed (272.8 s, 5.49, 1,743 VRAM experts) because its 2.5 GB pinned
buffers did not allocate.

**Lookup/suffix** (`nffx…`, zero-weight, lossless via the existing verify):
chat/summarize off 5.63 vs on 5.68 (2 drafts, 0 accepted); verbatim copy 4K /
128 tokens **off 4.54 vs on 5.73 (+26%)**, 78/78 drafts accepted, 2.61 tokens a
round. The first lookup build crashed in `verify` because `d_ints` and
`ring_bak` were allocated only when `n_mtp > 0`; the fix allocates them for
non-drafter packs and caps drafts at `kWin-1`.

## 9. Next session

1. Keep the lookup build as a copy/edit profile; test a 32K verbatim copy and a
   real agent edit loop, and gate `--lookup auto` where copy-shaped. Do **not**
   pursue DSpark/MTP or DAX on this 7.4 GB host: both measured negative.
2. Prefill remains the 1.0 GB/s `pread` path. A DAX port needs a registered
   window that fits a 2.65 GB layer (early registration, smaller host footprint,
   more host RAM, or a different transport), not another flag.
3. The resident serve 5.9 tok/s / 10.8 s warm-slot result stands; the Qwen
   restore and page-quality decision remains. `pack-dspark` and the 8 GB drafter
   can be deleted if space is needed; the original pack is untouched.

## 10. 2026-11-01 — the lane was measured; the baseline moved; the gate is DRAM

**The lane is not hypothetical, and §3's modelled band did not survive contact.**
§8/§8b measured **5.4–5.9 tok/s decode** and **38–52 tok/s prefill** on the GSQ
IQ1_M pack (48% hit, 1,871 VRAM experts, 1.0 GB/s `pread` prompt stream), with
DSpark below the clean baseline (3.59–4.71 against 5.80) and the DAX port refusing
a 2.65 GB layer out of memory. §3's 8–12 tok/s band assumed a prompt-seeded hit
rate and a working store; neither appeared (store allocated 0 of 229 slots).

**The comparison baseline moved the other way, by ~2.5×.** Since §8 was written the
Qwen lane gained 0.2.7's residency-biased router (`STRATA_ROUTE_PRIOR=1.2`) and
`--kv-grow`: decode 22–26 → **57.3 / 64.5 tok/s** on the 4.2K / 3.5K cells and 78 on
the 26K cell, prefill 1,245 tok/s at 26K. The §8 comparison ("430 s cold against
Qwen's 283 s") therefore understates the gap: the same 13.6K-in / 1K-out call is
258.6 s prefill + ~170 s output ≈ **430 s** on DS4.1 against **~28 s now (~15×)**. A
283 s refresh becomes ~4,300 s, breaching the 1800 s reflect wall clock by ~2.4×.
The lane cannot take the boot slot at the measured rates, and no lossless flag
changes that.

**The binding term is the host, not the Optane module.** Prefill reads at 1.0 GB/s
through `pread` — not 6.8 — because the DAX window cannot register a 2.65 GB layer
on a 7.4 GiB host (§8b), and the store sizes from `available − 12 GB` so it is off.
More DRAM fixes both at once: a 2.65 GB layer registers with room to spare, the
store becomes real, and the page cache replaces the fsDAX `pread` path. A second
DCPMM raises the module ceiling 6.8 → ~12–13 GB/s but fixes neither, so **it does
not unlock the lane on its own**.

With ≥128 GB DRAM the ~120 GB expert set fits in RAM; prefill then runs at the PCIe
link's 12.2 GB/s against the 350–650 tok/s compute ceiling, and decode becomes
VRAM-hit + PCIe-copy bound — the Xolotl-class 4090 + 90 GB operating point
(25.7 tok/s), not the 5.8 measured here. Hardware on hand (user, 2026-11-01):
6× 32 GB DDR4 that does not POST on this host, and 5 spare 128 GB DCPMM modules.

**Re-entry criteria:** prefill ≥ 300 tok/s and decode ≥ 10 tok/s on a real refresh
prompt, else the lane stays a quality experiment. Both need the DRAM population
first; DCPMM interleave is the second step, and rebuilding an interleave set
destroys the /optane namespace (Qwen packs: 86.3 GB re-download + ~7 min repack, §5).

**Quant note (Unsloth v3.1, 2026-10-31):** `UD-IQ1_S` 233.0 GB and `UD-IQ1_M`
250.4 GB both bundle the 110.6 GB Engram table, so the expert backbones are **122.4
and 139.8 GB** against GSQ IQ1_M's 120.7 GB — IQ1_S is the byte-neutral pick (+1.4%)
and still scores 83.53 against 81.78 on Unsloth's 6-task average (Aider 36.5 vs
29.8). Upstream v0.2.9 reads Unsloth `UD-IQ1_S`/`UD-IQ1_M` and the 4-shard DeepSeek
layout, so no fork is needed to load them.
