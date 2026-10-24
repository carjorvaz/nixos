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
  The CPU lane is memory-bound and **not** the wall.
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
  store itself **does work for IQ1_M** (a GGUF layer is `kFmtMXFP4` layout with the
  real IQ type in `K[r]`); only the floor blocks it. `--ssd-cache 3` +
  `DS4_STORE_FLOOR_GB=1.5` + `DS4_STORE_RESERVE=32` is a no-code ~3 GB RAM tier
  (≈400 experts, top ~70/layer). 4 GB gives ~535 experts (top ~73/layer).
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

Expected operating point: **8–12 tok/s** (6.4 pessimistic, 15 optimistic). For
comparison, the Qwen lane runs 20–22 tok/s; DeepSeek is ~2× slower, but a 763B model
at 8–12 tok/s on a 2080 Ti / 7.4 GB box is the surprising part. The biggest unknown
is the adaptive hit rate, not the arithmetic.

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

Minimum destructive action that keeps the production Qwen lane rebuildable:

```sh
rm -rf /optane/strata-data                         # 107 G; the PLE table goes with it
rm -rf /data/qwen2080-orchestration-20260906       # 67 G (retired lane; 41 G gain-source)
rm -rf /data/strata-models/coder-IQ1_M             # 27.6 G (coder shard 1; re-downloadable)
rm -rf /data/strata-staging                        # 1.5 G (rebuilt in 6 s)
```

Keep `/data/strata-models/IQ3_S/` (51.05 GiB shard 1). Result: `/optane` ≈123 GiB
free (backbone 112.43 + pack/headroom ≈ 118 → ~5 GiB spare); `/data` ≈126 GiB free
(Engram 103 + 5.6 headroom → ~17 GiB slack). Qwen recovery needs the **PLE shard 2
re-download (28.80 GB, `316b46f3…61e113`)** plus MTP (~6.5 GB); packs rebuild in
~7 min (46.84 GiB `experts.bin` 4m31s, dense 6s, PLE copy 59s). The coder lane would
need its 29.61 GB shard 1 again. The `qwen2080` 41 GB BF16 gain-source is the only
canonical copy; the receipts survive, but that retired lane cannot be rebuilt from
local data.

## 6. Experiment sequence (after a go)

1. Record the Qwen service health, free space, and the IQ3_S shard sha; stop
   `tiberius-strata`.
2. Delete the four paths above; verify free space.
3. Download the four IQ1_M shards (120.72 GB) to `/optane/dsv41/model/` and the
   Engram (110.60 GB) to `/data/dsv41/engram/`; skip DSpark. Verify SHA-256.
4. `pack_gguf.py` with the final layout, `--engram` pointing at `/data`, the 5.8 MB
   Unsloth metadata shard for `--engram-meta`, and the shipped
   `data/dsv41/profile-2.00.bin` copied in as `expert-profile.bin`; run
   `strata-dsv41 --pack-info`.
5. First run:
   `--pack /optane/dsv41/pack --mmap-experts on --prefill-chunk 4096
   --ssd-cache 3 --ssd-policy lfu --cpu-threads 11 --max-context 8192
   --dspark auto --verbose`
   with `DS4_STORE_FLOOR_GB=1.5 DS4_STORE_RESERVE=32`. Capture the `--verbose`
   `pm.disk/pm.dma/pm.cpu` rates, the accepted chunk, the store hit rate, and free
   RAM. If the 4096 chunk is accepted and the store has slots, the model is live.
6. Tune in this order: chunk 4096 vs 8192; store 0/2/3/4 GB; `--vram-experts`;
   `DS4_CACHE_*`; then `STRATA_DS4_DISK_SKIP_W` only after fixing `in_ram()` for the
   store, with a KL/top-1 check. Keep the prompt skip on; keep DSpark off.
7. Run the hindsight refresh job on the DeepSeek lane and compare its wall time and
   page quality with the Qwen lane's 283 s. DeepSeek output is ~2× slower per token,
   so it needs fewer calls/tokens or a quality win to be worth keeping.
8. If not: re-download the PLE 28.8 GB + MTP 6.5 GB, rebuild the iq3_s pack, restore
   the Qwen service, and verify `/health` + the answer hash.

## 7. Decision

The disk fits, the engine builds and passes IQ1_M kernels on sm_75, and the arithmetic
supports **8–12 tok/s decode and 350–650 tok/s prefill** with the store/chunk tricks —
not the 4 tok/s the planner's spill verdict suggests. The remaining unknowns are the
adaptive hit rate, the 7.4 GiB RAM pressure with the chunk buffers, and the Engram on
SATA. It is worth one bounded experiment if the DeepSeek quality is the goal; it is
not a speed win over Qwen.
