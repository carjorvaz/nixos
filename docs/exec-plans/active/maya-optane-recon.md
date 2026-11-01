# Maya (GLM-5.3-Flash) on tiberius' Optane — reconnaissance and decision

Status: **reconnaissance, not an approved lane.** Written 2026-10-12 from a 5-stream recon
(model config + quant recipes, `hosts/tiberius.nix` + `profiles/nixos/strata.nix`,
`pkgs/strata-sm75/tiberius.patch`, the project-maya source, external measured results).
Labels: **[M]** measured (repo/upstream, source named), **[D]** derived arithmetic, **[E]** estimate.

## 1. Bottom line

**Buildable, tunable — and still the wrong box for this model.** After taking every Optane
lever the hardware allows (direct DMA window on the prefill path, registered fixed-slot arena
for the decode refill, an LRU/pinned expert cache in the freed VRAM), the ceiling for
GLM-5.3-Flash on tiberius is **~5–10 tok/s decode best case, 1–3 tok/s all-miss**, against the
incumbent Qwen3.8 lane's **20.4–26.2 tok/s [M]** on the same GPU. The gap is not in the
storage plumbing; it is the per-token expert working set:

- GLM routes **8 of 288 experts × 42 MoE layers = 336 of 12,096 experts → 2.8 % of the expert
  pack per token [D]**; at the pack's ~2.2–2.4 bpw that is **~2.4 GB/token of routed-expert
  bytes alone [M, atlas: 42×8×14,155,792 B → 4.76 GB at 4.5-bit; 2.41 GB at IQ2_XXS]**.
- The Optane moves **6.8 GB/s** for pack reads [M, `strata.nix:29`] and at most **12.2 GB/s**
  over the PCIe link with direct DMA [M, ab8/ab10 probe]. Decode in this regime is an additive
  chain (the 3090-fork measured copies + kernels + dense with no overlap), so
  `tok/s ≤ 12.2 / 2.4 ≈ 5` — before cache, before compute.
- **No speculative multiplier is configured — but the sm_80 "requirement" is a *policy default, not a gate*.** `maya.py:884-894` picks MTP when `min(archs) < 80`, but `--draft dflash2` returns earlier (`maya.py:889-890`) and bypasses it; the engine never checks compute capability. The drafter (`src/core/glm_dflash.cu`, FP32 forward + quantized `gf::mv` GEMV) uses tensor-core mma only under `#if __CUDA_ARCH__ >= 800` **and** a runtime `mma_arch()` check, with a **bit-identical dp4a fallback** (sm_61+). So sm_75 is a measurement risk (64 KB smem for the non-split window attention; dp4a-only speed), not a port. Separately, the union math says speculation is break-even at best here: a K-draft verify round reads the *union* of experts ≈ `288·(1−(280/288)^K)` per layer ≈ 20 % more bytes than one token at K=4, and pays off only if accepted-tokens-per-round > ~3.4 (MTP measured neutral/negative on GLM).
- The one measured pure-storage GLM-5.3-Flash result is the same engine family on a *better*
  box (RTX 3090 24 GB + 251 GB RAM + 2× NVMe, page cache cold): **1.15 tok/s [M]**; the same
  fork with a RAM tier reads 13.9–19.8 tok/s.

## 2. Why every lever lands where it does

| Lever | What it actually buys on tiberius | Evidence |
|---|---|---|
| Sliding DAX window (`STRATA_REGISTER_DAX`, 6144 MiB) | **+22–28 % prefill, ~0 % decode** (decode never rotates the window — 48 register/unregister pairs/token) | [M] patch header; ab8/ab10 |
| Registered refill sources (`STRATA_REFILL_PIN_SRC`) | registers each batch's pageable **pack** spans before the copy, merged (straddle-safe), released on event completion. Not a tier mechanism — the deployed 1 GiB tier is irrelevant to it. Measured here: pageable copy **0.866 → 0.003 ms/2 MiB** (a latency/overhead cut — the copy is then async/overlapped; the *stream rate* still bounds throughput), worth **+12.2/+7.1/+5.9 % decode** at the Qwen lane's ~18 % miss. At Maya's ~84 % miss the same serialized tax binds harder | [M] strata.nix:400-417; tiberius.patch:838-859 |
| Expert cache in freed VRAM | 22 GB − ~6.9 GB resident (the engine's own measured "weights every token uses") − KV ⇒ **~12–14 GB of cache over an ~86 GB routed pool ≈ 16 % capacity [D]**. Optimistic hit branch (65–75 %, bounded by real LRU traces) → 0.6–1.1 GB/token → **6–11 tok/s [E]** | [M] MAYA-S24.md; atlas LRU traces |
| Direct DMA from PMEM (the strongest possible move) | removes the staging hop: the copy path moves from the 6.8 GB/s software rate to the measured 12.2 GB/s PCIe link — **the ceiling doubles at most, the answer does not**: 2.4 GB/token still costs ≥200 ms. (Device-capability probe in flight: whether the DIMM itself can sustain > 6.8 GB/s, or the link > 12.2, is being measured on-box) | [M] ab10 PCIe probe; probe A in flight |
| CPU-side experts / AVX-512 | **closed**: Xeon Gold 6246, AVX2-only (engine logs "no AVX-512"), ~2 DIMMs of DDR4 ≈ 20–25 GB/s — no bandwidth to spare | [M] VALIDATION.md:253-256 |
| Lower-bit quant | only IQ2_XXS-class fits the 126 GiB budget — a quality tier below anything the incumbent trades | [D]/[M] pack sizes |
| Runtime expert skip (`STRATA_GLM_TRUNK_KEEP`/`_MAP`, per-layer digit) | **the one lever that cuts the Optane stream directly**: drops any routed expert that is *not in VRAM* whose live router rank ≥ n — [M] +23 % decode (20.0 → 24.6 tok/s) and 5.9 % prefill, KL 0.018 from the full model, on Maya-M (3090+3060, 21K ctx; that rig's VRAM hits 64–69 %). No GPU-count gate in code; opt-in, answer-changing | [M] SETTINGS.md:60; CHANGELOG #103; `glm_fast_path.cu:4240-4259` |

**The trunk lever is the biggest cheap lever on this box — and the one with the largest quality risk.** Its saving *is* the Optane stream here (84 % of expert reads are misses), but the cut is bounded by per-layer residency: with only ~6–8 experts per layer in VRAM, `KEEP` must sit at 3–5 to bite, which drops *routinely-important* experts, not tail ones. The published KL 0.018–0.032 comes from a 64–69 %-hit regime where only the tail is skipped; at low residency the same KEEP skips rank-2-3 experts and must be re-measured on-box with the engine's own KL path (`STRATA_GLM_SCORE` + `kl_eval.py`).

**Speculative decoding: byte-neutral at best, and now measured, not deduced.** A K-draft verify round reads the *union* of experts per layer, `U(K) = 288·(1−(280/288)^K)` (uniform bound: 8 / 15.8 / 30.7 / 58.1 experts at K=1/2/4/8). Real routing is *not* uniform-iid — measured lag-1 reuse is **12.5 % (Maya, traced: "~1 of 8 experts shared") to 24.6 % (strata-glm-3090, 16 real segments)** — so the measured-anchored union is ~14 experts/layer at K=2 (**~1.75×** a single token's read) rising slowly; the uniform ceiling caps compression at **1.5×** by K=32 and the realistic band is **1.05–1.3×** at K≤8. Published GLM drafter results match: parity-or-worse on the 11 GB rig and spec-3 within spread on the 3090 fork; +19 %/+12 % where experts stream from *DRAM*. DFlash2's sm_80 is a support/policy default only (`maya.py:889-890` bypasses it; the CHANGELOG notes it *was measured* below sm_80 — slower on V100s), so Turing is a measurement question, not a port.

**Prefill is the one place with headroom, and it is not the bottleneck.** The routed-expert
union saturates at ~288 experts/layer for any real chunk, so prefill reads the pack, not the
per-token route: GLM ~89.7 GB experts vs the incumbent's 46.8 GiB pack ≈ **1.9× the bytes per
chunk [D] — and since the DAX window reads the pack at the measured window rate (6.6–6.9 GB/s; ~12.2 is DRAM-sourced only), expect GLM prefill in the incumbent's measured class or somewhat above (**~500–1000 tok/s [E]**, sm_75 KDA/DSA compute unverified).
The cost is concentrated in **decode**: the hindsight refresh's ~2 KB page at 3–5 tok/s alone
adds 400–670 s to a job that measures 283 s today [M]. For the refresh pipeline that is a
**~1.6–2.5× job-time hit, not 6–20×** — still the wrong trade, but for the right reason:
output tokens, not input.

## 2b. Measured findings (2026-10-12, in-box + artifact recon)

Two tracks were run against the box's stored probe artifacts and sysfs; both change the picture.

**The Optane module is the wall, and it is exhausted.** Every access path lands at the same rate —
CPU mmap of the fsdax file (6 threads, random blobs): **6.88 GB/s**; H2D copy out of the registered
DAX window: **6.57–6.87 GB/s** (flat across ring 8–64, odepth 16–3000); SM zero-copy read of the
DAX alias: 6.61–6.64; pageable (unregistered) H2D: 2.3–2.4; the PCIe Gen3 x16 link itself from
*DRAM*: **12.2–12.3 GB/s**. The device facts explain why: **one DCPMM module (`nmem0`), 126.0 GiB,
no interleave (`mappings=1`), in a single channel alongside a single 8 GB DDR4 DIMM — 1 of 6
channels populated.** The 6.8 GB/s is the module's read ceiling, not a copy inefficiency: no
software path (registration, zerocopy, staging removal) can raise it; only DRAM-sourced traffic
reaches 12.2. Consequence: the *only* remaining lever on decode is **bytes per token** — hit rate,
which the cache lever below addresses, and routing structure, which the next finding bounds.

**Routing does not compress enough to escape the floor.** Measured across three independent GLM
rigs: lag-1 expert reuse 12.5–24.6 %; ~6.5 distinct new experts/token within a pass; and concurrent
independent requests share essentially no experts — Maya's own `--parallel` measures **×1.41 (2
req) / ×1.35 (4 req)** on the RAM-bound V100, i.e. dense-weight amortization only, matching the
`U(N)` ceiling (1.93× at N=2, saturating at 288/layer, needing N≥64 to matter). So batching and
speculation both stay in the **1.0–1.5×** band, not the 2×+ class, and the re-read of the 2.4 GB
per token stands.

**But the VRAM expert cache is stronger than assumed.** Measured on Maya's own single-GPU run:
**31 % of expert slots (3,738/12,096) already covers 74–82 % of VRAM hits** (profiled placement;
topic-dependent, and code/prose share <10 % of top experts). Maya-S24's freed VRAM (~12–14 GB)
buys roughly that slot ratio, so a **60–80 % hit rate is plausible** for a single-domain workload —
which at 6.8 GB/s gives `2.4 GB × (1−h) / 6.8`: **h=0.5 → 5.7 tok/s; h=0.75 → 11.3; h=0.8 → 13.8**.
That is the *only* lever that moves the number into double digits, and each hit point is worth
~0.35 tok/s. It also explains why the current engine already runs well: the strata lane's 82 % hit
on Qwen is the same mechanism.

## 2c. Deployability facts (Track C, measured)

- **No partial-pack mode, at all** (`FileExpertSource::open` and `ArenaExpertSource::open` both
  refuse a size mismatch; `iq_pack.py` has no subset option). Any Maya test = full 94.7 GB S24
  download + deleting the strata packs (126 GiB, ~70 GiB occupied).
- **sm_75 is fully supported by the build** (`arch_setting` passes 75; CUDA ≥12.0; box has 12.9 in
  the store, driver 595.71.05 ≥ 525 floor). Turing runtime fallbacks exist and are **not**
  performance-validated for GLM: prefill attention uses the `tcreg` register kernel (the wmma path
  needs 91 KB smem > Turing's 64 KB), and `mvc_mma_*` int8 GEMVs are sm_80-only → **dp4a always**.
- **Maya's default expert mode (arena) cannot start here**: it allocates the full ~86 GB in
  anonymous memory. The only usable path is `--mmap-experts` (FileExpertSource) — which also means
  Maya's page-cache tuning (FADVISE_WILLNEED/DONTNEED, `DROP_CACHE`) is inert on a `dax=always`
  file. There is **zero DAX awareness** in Maya; the strata DAX window/RPC machinery would have to
  be ported (it is a delta on the same `FileExpertSource` shape Maya kept).
- **Upgrade paths are separate and must be priced separately.** (i) *Optane speed*: adding a second **DCPMM module** in an interleave set is the only thing that can raise the 6.8–6.9 GB/s PMEM ceiling — a second DRAM DIMM cannot (channel 0 already sources the full 12.2 GB/s link from DRAM; the wall is the module). (ii) *DRAM tier*: more **DRAM** buys Maya's tier-2 (its sizing = free RAM − headroom) — the lever that took the 3090 fork from 1.15 to 13.9–19.8 tok/s — but this box has 7.4 GB total and no spare DIMMs, so tier-2 stays empty either way. No more RAM is available: the plan below assumes the current 7.4 GB.

## 2d. Disk reality and the staged roadmap (measured 2026-10-12)

- `/optane`: 124 GiB, **88 % used** (packs 74 GB + PLE 27 GB + MTP 6.5 GB) → 16 GB free.
  `/data`: 206 GB zdata, **84 % used** (35 GB free), a **SATA SSD** (`TOSHIBA-TR200`/`KIOXIA-EXCERIA`),
  i.e. ~0.5 GB/s class — no NVMe on the box. `/persist`: 90 % used (20 GB free).
- Maya-S24 needs ~91 GiB (88.2 GiB model + 1.0 GiB encoder). It fits only in `/optane` after the
  packs go; it cannot be staged on `/data` (35 GB free, and SATA speed makes a run there
  unrepresentative — 12× slower than the PMEM). **Native-GGUF mode** (`--glm-pack` on the GGUF
  dir, no `experts.bin` written) keeps the footprint at the download itself — prefer it.
- **The wipe is recoverable**: the raw source GGUFs live on `/data/strata-models` (IQ3_S shard 1
  51 GB + coder 28 GB), so re-running `iq_pack` rebuilds the packs (hours of CPU, no re-download).
  What is *not* recoverable in place is the PLE table unless it is regenerated by the same flow.
- **Stage the work so nothing irreversible happens before the earlier gate passes:**
  1. **Non-destructive: build + synthetic bring-up.** `-DCMAKE_CUDA_ARCHITECTURES=75`; then Turing
     kernel correctness via the repo's own fixtures — `tools/glm_synth_gguf.py` (structurally
     complete scaled-down glm5-next: KDA, DSA, dense, MoE, mHC) and `tools/glm_big_fixture.py`
     (45-layer F32, ~30 s CPU) run through the native GGUF path. No real weights, no Optane hit.
  2. **The 94.7 GB download** — only after 1 is green; stage directly to `/optane` post-wipe or
     keep it out entirely if 1 fails. Gate on measured per-job time vs the incumbent's 283 s
     refresh (the honest criterion — 3–5 tok/s may already be sufficient for a 2 KB output page).
  3. **The registered-DAX port** (steps 2–3 below): the biggest engine lever, priced from the
     box's own numbers — pageable 2 MiB copies run **~2.3 GB/s (0.866 ms)** vs **6.57–6.90 GB/s**
     out of the registered window, so the port targets **~2–3× on the miss-dominated path**
     (unmeasured for Maya's blob sizes) — i.e. **~1–2 tok/s naive pageable vs ~2.9–8.5 windowed**.
  4. **Hit-rate + trunk-KEEP measurements** with the engine's own tools (`glm_tier_replay.py`,
     `STRATA_GLM_ROUTE_LOG`, `STRATA_GLM_SCORE` + `kl_eval.py`). Expected hit band at ~16 %
     slot capacity: **~50–65 %** (interpolated from measured real-weight coverage: top ~11 % of
     experts ≈ 42–64 % of routed mass), i.e. **~5.7–8.5 tok/s** at the window rate, ~1–2 naive.

## 3. The deep-work plan, if we build it anyway

Bounded, in order; each step has a measured (strata) or derivable gain and a kill criterion.

1. **Port + package** — `pkgs/maya-sm75`: `-DCMAKE_CUDA_ARCHITECTURES=75` (CMake already
   admits 75; CUDA 12.x/13 both fine for RTX 20). Keep the existing kernel stack
   (`fsdax_longterm_pin=1`) — it is the precondition for any `cudaHostRegister` on DAX pages.
   *No gain; gates everything.* ~1–2 weeks incl. a V100-free CI pass.
2. **Prefill: sliding DAX window.** Port the portable half of `tiberius.patch` (the window is a
   self-contained delta on `FileExpertSource`; Maya kept that class shape — `experts.bin` mmap,
   layer-contiguous blobs, its own port study calls the tier machinery reusable). Integration
   surface: Maya's prefill walk (its `glm_prefill.cu`/`glm_window.cu` layer hooks) + one DMA
   stream. *Buys the measured +22–28 % prefill.*
3. **Decode: registered fixed-slot arena.** Instead of a sliding window, register a **stable
   ~6 GiB arena** of the hottest expert blobs on the Optane and DMA them directly to VRAM from
   the DAX alias on miss — plus port the `STRATA_REFILL_PIN_SRC` idea (register each batch's
   pageable spans before copy, merged, release on event completion). Needs Maya's reader to
   expose `blob_class`/`registered_ranges` (its O_DIRECT `direct_file` path must learn the
   mmap/DAX source). *Buys the copy tax — measured 0.866 → 0.003 ms per 2 MiB on this box in
   the Qwen lane's ~18 %-miss regime; at Maya's ~84 % miss the same class of saving is larger.
   Not the bytes.*
4. **Cache: profile-driven.** Ship a GLM expert profile (`tools/glm_expert_prior.py` exists),
   LFU admission, conversation-slot pinning. **This is the only 2×-class lever** — and it is
   bounded by routing locality, which is unmeasured for GLM on this box.

**Kill criterion, stated against deployability reality:** Maya has **no partial-pack mode** — the engine loads the full split pack, so every probe below requires the complete Maya-S24 download (94.7 GB) *and* deleting the strata packs first (126 GiB total, ~70 GiB occupied). Budget the probes as full-lane setups; only the sm_75 build is an afternoon. Then: if the measured lane fails to clear **≥ 8 tok/s decode at a measured ≥ 60 % expert-cache hit rate, or ≥ 1.5 GB/token effective miss stream**, the lane stops — the arithmetic says that is the best case, and it is still ~2.5× behind the incumbent.

## 4. Costs and risks

- **Capacity:** Optane is 126 GiB and half-full today (iq3-s 46.8 GiB + coder 23.4 GiB packs).
  Maya-S24 (94.7 GB) + encoder (1.1 GB) fits **only after deleting the strata packs** (~135 GB
  usable); keeping both does not fit. "Bring strata down" means delete its data.
- **RAM floor:** Maya's README floor is 32 GB; tiberius has 7.5 GB with ~2 GB free at engine
  start. The engine pins most free RAM for its tier — on this box the tier is ~1.5 GB and the
  start-time behavior is untested.
- **FSDAX semantics:** Maya has **no PMEM/DAX code**; an fsdax XFS mount is opaque to it
  (no DRAM page cache — DAX pages displace nothing). Works, but it is "a filesystem on Optane"
  until step 2/3 land.
- **Risk that the port is not a port:** the strata refill hunks are anchored in Strata's
  adaptive-refill internals; a Maya rebase may not accept them. The window is the portable
  asset; the arena (step 3) is a *new* design, not a port.
- **License:** engine + quants MIT; DFlash2 drafter CC BY-NC-ND — opt-in only, and the union math
  makes it non-binding here.

## 5. Decision

**No lane on tiberius as configured — and this is now measurement-backed, not deduced.** The
drive's read ceiling is **6.8–6.9 GB/s on every path** (mmap, registered-DMA, zerocopy — flat in
queue depth; the 12.2 GB/s link is reachable only from DRAM); the module is one DCPMM with no
interleave in 1 of 6 populated memory channels. Combined with 2.4 GB of routed-expert bytes per
token and ~12–25 % measured routing reuse, the expected operating point is **~6–11 tok/s** at a
60–75 % VRAM hit rate (~5.7 at 50 %) — i.e. **~4× behind the incumbent Qwen lane** on the same
GPU. All remaining uncertainty is *disk and time*, not knowledge: the probes require deleting the
strata packs (no partial-pack mode exists) and ~95 GB of download. The two honest ways to run
GLM-5.3-Flash locally are (a) the measured **128 GB-RAM** path (11 GB 2080 Ti + 128 GB DDR4:
12.0 tok/s [M]) — which its owner calls "glacial", so doubt the compute, not the RAM tier — or
(b) a **second DIMM in channel 1**, the one cheap experiment that can change the ceiling
itself. Keep the strata lane; revisit when either (a) or (b) exists.
