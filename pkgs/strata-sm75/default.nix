{
  lib,
  stdenv,
  fetchFromGitHub,
  cmake,
  ninja,
  cudaPackages,
  symlinkJoin,
}:

# The Strata engine, built for Turing (sm_75) from the pinned source revision.
#
# The pin is the whole stack: the engine source (which since 0.2.13 carries the
# ggml sources it builds, vendored in third_party/strata-ggml at llama.cpp
# 3cf03257 - no separate download) and the CUDA toolkit.  Only the engine is
# built here -- the model files (pack, experts.bin, PLE GGUF, MTP) are prepared
# once on the host by the setup flow and live on /optane, not in the store.
#
# tiberius: CUDA 12.9 from nixpkgs, sm_75 only.  The 22 GB RTX 2080 Ti runs the
# engine with --mmap-experts, so this build only needs the sm_75 i-quant kernels
# and the driver's libcuda.so.1 at runtime (the module adds it to the service's
# LD_LIBRARY_PATH).
let
  c = cudaPackages;

  # d2f0964: v0.2.13 (2026-11-09), the current release.  The engine inside it is
  # 0.1.59.  Since the last pin (146df3c4 = v0.2.12 / engine 0.1.58) the release is
  # mostly app/Control and Qwen4-groundwork work; the engine-side changes this lane
  # can see are:
  #   * the build: root CMakeLists.txt split into cmake/backends/*.cmake (the per-TU
  #     kernel flag lists moved verbatim), the ggml sources the engine builds
  #     vendored in third_party/strata-ggml (llama.cpp 3cf03257 - the same pin, so
  #     the derivation fetches no llama.cpp), and the model shape fixed at configure
  #     time (-DSTRATA_GEOMETRY, default flash_next - the shape this lane serves;
  #     upstream reports the default Flash-Next build unchanged: CUDA SASS 3573/3573,
  #     no kernel changes).
  #   * STRATA_HC_Q8: on Linux CUDA a GGUF that carries the hyper-connection
  #     projections as Q8_0 (Unsloth's UD-* files) now reads them as Q8_0 by default
  #     (was setup.py's unsloth_default_env).  The deployed UD-IQ2_XS dense file does
  #     carry them that way (output_hc_* and blk.*.hc_{attn,ffn}_{down,up} are type 8
  #     in its GGUF header, checked on the box 2026-11-09), so this lane - which never
  #     ran the setup env - moves from the dequantized BF16 read to the Q8_0 bytes:
  #     an answer-rounding change and less VRAM.  STRATA_HC_Q8=0 is upstream's
  #     escape; the generation-113 gate measured the move speed- and quality-neutral
  #     (docs/VALIDATION.md) and the module pins STRATA_HC_Q8=1 explicitly so a later
  #     release cannot flip it back.
  #   * the launcher-env stacks moved engine-side: the exact parallel-request stack
  #     (only at 2+ batch slots; this lane runs one) and the GDN stack
  #     (STRATA_GDN_TC=1 / STRATA_GDN_CONVL2=2 on Linux CUDA) - the GDN values are the
  #     ones 0.1.58's serve/server.py already set for this config (no "arch" key), so
  #     that half is unchanged.
  #   * #5327 (PR #5531): on Linux an expert-arena shortfall that free pages plus the
  #     droppable file cache (or the reserved hugetlb pool) can serve now loads
  #     through the file cache instead of falling back to --mmap.  That is
  #     ArenaExpertSource's open only; this lane runs --mmap-experts (hostTierGib = 0)
  #     and uses FileExpertSource, so it is INERT here.  STRATA_ARENA_FILE_CACHE=0
  #     restores the 0.1.56 refusal.
  #   * serve layer: the tool-call parser is picked from the chat template
  #     (serve/toolformat.py), the tokenizer refuses an UnknownPreTokenizer, and the
  #     launcher-env stacks above were removed from serve/server.py.  The WSTAT
  #     readers are untouched: 0.2.13 still has exactly four `_parse_done` sites and
  #     all four parse WSTAT before DONE - no fifth finisher.  The agent lane's
  #     answers can move with the parser.
  #   * DFlash2: this release's per-card defaults (Strix Halo; Blackwell cc 12.0 with
  #     >= 48 GB: window 8, conf 0.55 for IQ3_S) are Auto-only, and this lane names
  #     the drafter ("drafting": "dflash2") on a Turing card, so nothing is re-chosen
  #     and the stock/converted pack stays.  The tuned pack still needs >= 12,000
  #     engine slots (drafting.py CONF_STEPS); this card's cache holds ~6.3-8.9k.
  #   * removed opt-ins: STRATA_DF2_GATE / STRATA_DF2_ROW_MS / STRATA_MMVQ_PF /
  #     STRATA_MMVQ_SG / STRATA_GR_Q32_PL / STRATA_METAL_* - none is set by this
  #     package or the module (0.2.12's DF2 screen had left the config unchanged).
  #   * not this lane: the Strix Halo Windows UMA reserve floor, Intel Arc's
  #     fixed-order bf16 products (SYCL), the gfx1100/1201 hipBLASLt table rule, the
  #     gfx1151 defaults and the Mac fp16 windows; `strata --geometry` is a query
  #     only and prints flash_next here.
  #   * the gates this package pins are unchanged in 0.2.13: the
  #     `o.pcie_frac_auto = ... && !pf_old` start-up gate (with
  #     STRATA_PCIE_AUTO_SPLIT / K_RULE / SHARE_MAX), the FP16 weight cache's
  #     batch-slots gate (o.batch >= 2), the --prefill bare-auto ceiling
  #     (prefill_auto_bare), nv_defaults.cpp's STRATA_MMQ_KQ, the Turing kernel
  #     series (sm75_series.hpp) and vram_fit's kv_fixed hook.  The qsa_select sm_70
  #     guard does not change an sm_75 result: that target is above the guard either
  #     way.
  # The AVX-512 expert tier this package patches is unchanged: upstream's gate split
  # (cpu_vnni_ok() / q2_rows_512_ok(), OPT-IN below VBMI through STRATA_VNNI_TIER=1 -
  # the module sets it) and avx512-bw-tier.patch's compile-time half (no VBMI in the
  # expert/iq/nvfp4 TUs).  The gen-112 screen measured the tier, q50_512 and
  # iq4xs512 as zero effect on the post-route-prior lane (the CPU pool sees ~0.8 % of
  # the window's expert rows); the tier is kept for rounding continuity.
  # The ggml sources the engine links are vendored in third_party/strata-ggml at
  # llama.cpp 3cf03257f219afbe7334045ff7c6a06ac68c627d (UPSTREAM.md; the same
  # pin as third_party/ggml/VERSION.txt), so 0.2.13 needs no llama.cpp fetch:
  # cmake/strata_ggml.cmake resolves the vendored tree when STRATA_GGML_DIR is
  # unset.  That is the path the release engines are built from; the override
  # (with its configure-time TQ overlay) is only kept upstream for two releases.
  revision = "d2f096475817d4666c364c820b0ca830f751cfc5";

  # nixpkgs splits the CUDA toolkit into many outputs and CMake's
  # find_package(CUDAToolkit) wants one root with nvcc, the CRT headers and the
  # cudart/cublas libraries beside each other -- exactly what the qwen38-sm75
  # package builds for its JIT, and what a manual `nix shell` build needed too.
  cudaHome = symlinkJoin {
    name = "strata-cuda-home";
    paths = [
      c.cuda_nvcc
      (lib.getDev c.cuda_nvcc)
      (lib.getBin c.cuda_nvcc)
      c.cuda_cudart
      (lib.getDev c.cuda_cudart)
      (lib.getLib c.cuda_cudart)
      c.cuda_cccl
      c.libcublas
      (lib.getDev c.libcublas)
      (lib.getOutput "include" c.libcublas)
      (lib.getLib c.libcublas)
    ];
    postBuild = "ln -sfn lib $out/lib64";
  };
in
stdenv.mkDerivation {
  pname = "strata-engine";
  version = "0.1.59";

  # The build host's CPU decides the codegen (NIX_ENFORCE_NO_NATIVE is cleared
  # below, and ggml compiles with -march=native).  tiberius's nix.conf lists
  # pius (an AVX2-only i5-8400) and trajanus (Zen 4) as builders, so a plain
  # nix build dispatches this derivation and the result carries the BUILDER's
  # instructions.  Measured 2026-10-11: the trajanus and pius builds of the
  # same drv differ in 50,132,344 bytes, and two instruction classes show up:
  #   * the engine's own AVX-512 expert kernels (expert.cpp) are built for
  #     F/DQ/BW/VL/VNNI and selected at run time by upstream's cpu_vnni_ok()
  #     (0.2.12's gate; on this VBMI-less Cascade Lake part it is true only
  #     because the module sets STRATA_VNNI_TIER=1).  Through 0.2.11 the shared
  #     gate demanded VBMI as well, which made the expert tier dead code here;
  #     avx512-bw-tier.patch supplied the VBMI-free gate then, and keeps the
  #     compile-time half now: expert.cpp and iq/nvfp4_avx512.cpp are built with
  #     no -mavx512vbmi, so the object cannot carry VBMI code this CPU family
  #     cannot execute (the built object has 0 vpmultishiftqb).  The trellis TU
  #     keeps the VBMI-requiring cpu_avx512_ok().  Measured 2026-10-12 (ab18
  #     campaign, 3 counterbalanced runs per arm): ~5 % cheaper CPU expert
  #     pool+plan per decode window, prefill and the Optane reads unchanged;
  #   * ggml's own `*_generic` fallback dots and `ggml_vec_dot_bf16` are
  #     compiled with the BUILD host's -march=native and carry no run-time
  #     gate: the trajanus build has 262 instructions the Xeon Gold 6246
  #     cannot execute (260 vpermt2b / AVX512-VBMI in the q3_K/q5_0/q5_1/q6_K
  #     generic kernels and 2 vdpbf16ps / AVX512-BF16 in ggml_vec_dot_bf16),
  #     the native build has 0, and the deployed v0.1.41 (also trajanus) has
  #     the same 262.  They were NOT reached in this config (16 campaign runs
  #     plus two days of production, all clean), but they are one fallback
  #     kernel away from a SIGILL for another quant type or lane - so the
  #     engine is built for the host that runs it.  preferLocalBuild keeps the
  #     dispatch local (tiberius builds natively; the darwin workstation still
  #     dispatches), and a non-tiberius consumer should pass -DGGML_NATIVE=OFF.
  preferLocalBuild = true;

  src = fetchFromGitHub {
    owner = "Niko1221";
    repo = "Strata";
    rev = revision;
    hash = "sha256-ygLtDYyrwfRKez46xKnPkO7BtY0Q4uMwxlvh3JyUHbE=";
  };

  # carry-1283.patch is GONE since the v0.1.42 bump: upstream took PR #1283 (commit
  # a26fcbcd), so tiberius.patch sits directly on the release trees.  At the
  # v0.2.7 bump (5e8a4cca) it was rebased by three-way merge: upstream rewrote the
  # adaptive refill again (the "resolve every swap first" plans pass, nib::guard_raw
  # and the batch H2D path), so our pin classification (BlobClass), the merged
  # page-rounded span registration and the straddle guard moved INSIDE that plans
  # pass; the two small conflicts (the adapt-join timing counter and the verify-run
  # decode_pool_fn) kept both sides.  no-web-ui.patch needed one merge: upstream put
  # /tool-media/ at the top of the GET router and our 404 block now returns above it.
  # avx512-bw-tier.patch merged cleanly except the sycl flag list, which now mirrors
  # the root (no VBMI, upstream's vpopcntdq/bmi2 kept).
  # The v0.2.8 bump (870aedd9) merged without hunk conflicts in tiberius.patch and
  # no-web-ui.patch (0.2.8's expert-cache reserve and engine hand-over changes sit
  # outside our regions); avx512-bw-tier.patch had one conflict in
  # cpu_require_expert_support(), where 0.2.8 rewrote the message to explain a pack
  # without native_experts.txt - upstream's structure with the VBMI-free ISA list.
  # The v0.2.9 bump (c62d5e3a) merged with no hunk conflicts in any of the three
  # patches: every file they touch moved only in line numbers, so the 0.2.8 delta
  # carried over unchanged.
  # The v0.2.10 bump (ffa80d73) needed two resolutions in generate.cpp, both
  # "keep both": 0.2.10 added keep_sync() exactly at tiberius.patch's
  # request-ending pin release (upstream's drafter-upkeep wait runs first, the
  # pins are released after it), and the loop's `drafted` guard was renamed
  # use_mtp -> draft_on upstream (upstream's variable with this patch's refill-
  # timing join).  no-web-ui.patch and avx512-bw-tier.patch applied cleanly; the
  # 0.2.10 expert_source changes (the ArenaExpertSource #4846 RAM fallback and
  # the Windows standby-list release) sit outside the FileExpertSource region
  # this patch owns, and the CMakeLists growth is new split/DFlash2 TUs and
  # comments, not the kernel flag lists.
  # The v0.2.11 bump (c3b3f503) needed three resolutions, all in serve/server.py.
  # Two conflicts were resolved "keep both": 0.2.11's per-line progress reset in
  # the two engine-line wait loops (every line restarts the stop limits) beside
  # this patch's WSTAT parse, and 0.2.11's `if not admission_rejected:` guard
  # (#3040) around the per-request totals, with the WSTAT aggregation block
  # re-indented inside it.  The third is an added hook: 0.2.11 can finish a
  # request in the `finally` drain loop (the early-consumer path), and that loop
  # consumed the WSTAT line without parsing it - observed on every 0.2.11 probe
  # request (telemetry silently absent from /metrics; answers fine) - so the
  # drain loop now parses WSTAT before DONE like the other three readers.
  # The engine-side hunks (expert_source.cpp, prefill.cpp and all of
  # generate.cpp's 1,314 added lines) applied with no fuzz, as did
  # no-web-ui.patch and avx512-bw-tier.patch; upstream's 0.2.11 delta in those
  # files (the PCIe share rule, the layer-split walk, DFlash2 batch slots, the
  # chat-store/stream serve changes) sits outside every region this patch owns.
  # The v0.2.12 bump (146df3c4) rebased all three patches.  tiberius.patch had six
  # hunk conflicts, all in generate.cpp, resolved "keep both" (the exact regions are
  # in its header): 0.2.12's STRATA_ADAPT_FETCH in-flight marks in the refill's plans
  # pass and at the end of its per-swap loop, the AdaptGate::Tick field rename
  # (AdaptGate* -> std::atomic<int32_t>*), the new STRATA_FOLLOW reader that landed
  # on the CUDA stop-bound port's comment and HIP #if (upstream's block kept, this
  # patch's unconditional stop bound kept), and the same marks plus upstream's
  # fetch_log read-back in the build-path plans pass.  serve/server.py applied
  # cleanly: 0.2.12's accounting rewrite (yielded legs, the admission token) did not
  # touch the four WSTAT readers and added no fifth DONE path.  expert_source.cpp,
  # prefill.cpp, the conversation_* files and prometheus.py took every hunk with no
  # fuzz, and no-web-ui.patch re-verified with no conflict.  avx512-bw-tier.patch was
  # SHRUNK: 0.2.12 upstreamed the VBMI-free CPU tier and its gate split (PR 5120), so
  # only the compile-time half remains - the expert.cpp unpacks and the
  # -mavx512vbmi removals in both CMakeLists; its header has the detail.
  # The v0.2.13 bump (d2f0964) rebased all three patches with ZERO hunk conflicts:
  # every change 0.2.13 made in the files they own sits outside their regions, so the
  # patch bodies are unchanged - only hunk offsets and `index` blob hashes were
  # refreshed (the added/removed line set is byte-identical to the v0.2.12 patches).
  # 0.2.13's delta in those files: generate.cpp's compiled-geometry change and the
  # engine-side arch defaults (parallel stack, GDN stack, STRATA_HC_Q8) that replace
  # serve/server.py's env stacks, prefill.cpp's geometry-width substitution,
  # expert_source.cpp's #5327 arena-shortfall credit (ArenaExpertSource only - this
  # lane runs --mmap-experts/FileExpertSource), and serve/server.py's tool-parser
  # selection plus the launcher-env removal.  The WSTAT audit still finds exactly four
  # `_parse_done` sites and all four parse WSTAT before DONE - 0.2.13 added no fifth
  # finisher.  avx512-bw-tier.patch was retargeted: 0.2.13 split the monolithic root
  # CMakeLists.txt into cmake/backends/*.cmake, so the per-TU kernel flag lists moved
  # verbatim to cmake/backends/cpu.cmake and the patch (and this file's postPatch
  # greps) follow them; src/kernels/cpu/expert.cpp is unchanged upstream and its
  # hunks are byte-identical.  The build moved to the vendored ggml (no llama.cpp
  # fetch) and to a configure-time compiled geometry (STRATA_GEOMETRY, default
  # flash_next - the release's own check reports the default Flash-Next build
  # unchanged), both asserted in postPatch below.
  #
  # tiberius.patch is tiberius's local engine changes, in one patch because the
  # first two interleave in the same regions of expert_source.{hpp,cpp},
  # prefill.{hpp,cpp} and generate.cpp (the third and fourth are independent: the
  # park fix and the streamed session restore + drafter invalidation below):
  #   * the STRATA_REGISTER_DAX sliding window, which makes the layer the prefill is
  #     reading DMA-able by the device without registering the whole 46.84 GiB pack;
  #   * STRATA_DAX_TIMING (added 2026-11-04): one log line per DAX window rotation with
  #     the stream-drain wait and the unregister/register driver times (off by default;
  #     log-only - the copy and the window are the same either way).  It exists because
  #     the rotation is the prompt path's remaining fixed cost: 9 windows per 46.84 GiB
  #     pack pass, each a drain plus an unregister/register of ~5.5 GiB, and the
  #     short/mid prompt's "wait copy" was 36.9-39.7 % of its GPU timeline (4,245-token
  #     prompt: 2,626 ms of 7,111 ms) against 3.7 % at 26k.  Measured with it on
  #     (single-window): wait 108-198 ms + unregister 65-87 ms + register 125-342 ms per
  #     rotation.  It was built to judge a pipelined TWO-WINDOW rotation (a run of ~2-3
  #     layers per registration, two windows resident under the same budget, the next
  #     run registered while the current one still streams, the stale run released after
  #     a per-window cudaEvent).  That was built and A/B-measured on 2026-11-04 and
  #     REJECTED: the fence wait is 0 ms, but an unregister that lands while the copy
  #     engine is active costs 60-260 ms/rotation (21.5 ms after a drain), the run cap
  #     doubles the rotation count from 9 to 19 per pass, and the 4,260/8,276-token
  #     reads lost 1.66 %/4.13 % while the 26,134-token read gained 5.43 % and its
  #     answer sha drifted (the frozen two-window state moves the decode's PCIe
  #     grouping).  The pipelined code is NOT in the patch; only the timing stays, as
  #     the measurement seam for any future rotation work.  Artifacts: /data/dax-ab
  #     (tiberius) and /tmp/strata-tune/dax-ab;
  #   * STRATA_REFILL_PIN_SRC, the decode-time VRAM refill read from registered sources,
  #     with its straddle guard;
  #   * the transactional park (added 2026-11-04): a park the physical-RAM admission
  #     gate cannot admit used to evict up to slots() parked conversations before the
  #     refusal and consumed the retained-K/V donor on the way (live: "need 994 MiB
  #     plus 384 MiB floor, 1102 MiB available; evicted 2, 0 still parked").  The gate
  #     is now pre-checked before make_room() and before any eviction, against
  #     available plus every evictable parked conversation's bytes; a park that could
  #     not fit over an empty cache skips with "nothing evicted, N still parked" and
  #     gives the donor back.  A park that can fit takes the old path unchanged; no
  #     upstream counterpart (#4677 is a different, HIP-only stop-bound park fix).
  #     Built 2026-11-04 on tiberius (/nix/store/3qla1qfa09rsf6rqmcnnndk04hrqvb0y-strata-
  #     engine-0.1.56, 7 min) and probed against the deployed pre-fix binary in an
  #     isolated window: pre-fix "evicted 2, 0 still parked" and the next request
  #     re-read the prompt the destroyed copy held; patched "nothing evicted, 2 still
  #     parked", both copies still restorable (1738 tokens restored, reused=1738),
  #     normal parks unchanged and all six answer shas identical.  Deployed as
  #     generation 101 on 2026-11-04 (system
  #     07pr3sndmbszvsyq8jayd334ak0nwf59, the engine store path above); the patch file
  #     is unchanged since that build, so the switch reused it.  See
  #     /tmp/strata-tune/park-patch.md.
  #   * the streamed session restore (round 5, added 2026-11-04): SAVE streams the K/V
  #     from the pools, but RESTORE materialised the whole SavedConversation in host
  #     RAM first, so a 250k session (3.89 GB file) asked ~3,727 MiB plus the 384 MiB
  #     floor and was refused on this 8 GB box.  The restore now reads the same file
  #     twice: pass 1 validates the v1 header/trailer/payload hash with metadata only;
  #     pass 2 re-parses it and streams each K/V section into the session pools through
  #     a 16 MiB pinned staging block, with the RAM gate moved after pass 1 to the exact
  #     metadata-derived peak (~270 MiB at 250k).  No file-format change; corrupt or
  #     truncated files are refused in pass 1 before any device write, and a failure
  #     after the first write keeps the old FATAL contract.  Measured on the isolated
  #     port-8099 engine 2026-11-04: 240k restore 5,240 ms with VmHWM +259 MiB and an
  #     identical greedy continuation sha; 50k save/restart/restore sha regression
  #     identical; an old-writer file from the MTP lane restores; cross-lane files are
  #     refused; the park regression is clean.  The same change fixes a pre-existing bug
  #     found in that window: SAVE unconditionally passed mtp.kv_state(), which is an
  #     empty QsaState on the deployed DFlash2-alone lane (no --mtp), so every SAVE
  #     there failed with "invalid K/V extent" - disk sessions had never worked on this
  #     lane.  SAVE/RESTORE now make the draft layer optional (layers + (use_mtp ? 1 : 0);
  #     MTP-lane files stay byte-identical, DFlash2-lane files are layers-only, a
  #     mismatched file is refused).  RESTORE also invalidates the DFlash2 drafter
  #     before the session goes live (its slot shadow describes pre-restore K/V
  #     otherwise).  Deployed as generation 103 (system 56fx2bk..., engine
  #     gv3vlx7ah...).  A hygiene regeneration then restored the four "payload ends
  #     early" over-read guards (In::raw, In::skip and both streamed K/V spans) and
  #     conversation_file.cpp's final newline that had been dropped in that cut - the
  #     only delta: one file, 4 guard lines + the newline - and was deployed as
  #     generation 104 (system j73nq77..., engine sz2dwc0k...).  See
  #     /tmp/strata-tune/stream-restore-design.md, -results.md and hygiene-round6.md.
  #     The round-7 pmem park-spill hybrid was then added (dormant: no run flags) and
  #     deployed as generation 106 (system idsww8aa..., engine 2fa52rq...); the same
  #     generation boots the volatile nlzy/turing-unlock module (host packages in
  #     pkgs/turing-unlock + profiles/nixos/turing-unlock.nix), measured prefill -5.7 %
  #     at 26,134 tokens / -2.0 % at 8,268 / -1.1 % at 4,252 at the production 280 W cap
  #     with identical answers; see docs/exec-plans/active/turing-unlock-assessment.md.
  #     Round 8 then fixed the pmem park checkpoint match (patch 1f2393f2: the park saves
  #     the deepest chain checkpoint >=1024 tokens below the live state, keeps the whole
  #     chain as metadata, and prefers a file candidate over a full reread) and enabled
  #     the tier in generation 107 (system 3i99wsnk..., engine gci3izr...; 6 GiB / 4 slots
  #     / 4096 MiB reserve + stale-*.park cleanup).  Round 8b added the CUDA #4677 stop bound and
  #     the per-request WSTAT telemetry counters (nine strata:* families + verify-window histogram +
  #     prefill phases on /metrics/prometheus and JSON /metrics; answers unchanged, counters
  #     reconcile with the engine log) and was deployed as generation 108 (system 7nac9cgx...,
  #     engine gwhnf6m...).  See the round-8 section of the plan.
  #   * the pmem park-spill hybrid (round 7, added 2026-11-05): the RAM park path is
  #     byte-identical; when the transactional pre-check (or the parked-cache budget)
  #     refuses a park, the conversation is written as a v1 session file under
  #     /optane (the same SAVE writer: live + deepest checkpoint, K/V streamed from the
  #     pools) and kept in a separate metadata-only file tier (ids/images/used only, no
  #     state, no K/V) with its own --conversation-park-dir/-mib/-slots/-min-free-mib
  #     budget and LRU.  A later turn restores it with the round-5 streamed restore and
  #     then invalidates the DFlash2 drafter like a disk restore.  A refused/failed park
  #     or a restore refused in pass 1 is non-destructive (the transactional contract:
  #     donor handed back, no RAM park evicted for a file, no half-restored session);
  #     no cudaHostRegister for park pages (the writer's 16 MiB block).  Format v1 and
  #     answers unchanged.  This cut is in-run only: boot re-admission of existing
  #     *.park files is not implemented (so a restart drops file parks; the files are
  #     deleted at startup/clear sites).  See /tmp/strata-tune/pmem-park-design.md.
  #   * the pmem park-spill checkpoint match (round 8, added 2026-11-05): the parked file now records the WHOLE
  #     checkpoint chain as metadata and saves the deepest checkpoint that is strictly shorter than the live state
  #     (the one the next turn's prompt actually starts with), the tier's matching only offers the saved checkpoint
  #     (the streamed restore can only rewind to it) or the live state, and a request that would otherwise reread the
  #     prompt from token 0 now takes a file candidate; STRATA_PARK_DEBUG=1 logs, per request, the candidates vs
  #     resume/slot/parked and, at capture, the chain's token lengths and the chosen one.  Metadata only: session
  #     format v1 untouched.
  #   * round 8b (added 2026-11-05): (a) upstream #4677's stop bound is ported to CUDA - a verify window that would
  #     commit past an EOS inside it commits to the stop token instead (same serve_stop_bound as HIP, unconditional;
  #     STRATA_SERVE_STOP_BOUND=0 still turns it off), and (b) a per-request `WSTAT` stdout line carries the counters
  #     serve/server.py aggregates on /metrics/prometheus: DAX rotations/request, the prompt path's borrowed bytes,
  #     verify windows/rows/accepted, the CUDA stop-bound clips, the prompt read seconds, windows by size and (with
  #     STRATA_PREFILL_TIMING=1) the prefill phase timeline.  Counters only: no answer or token change.
  # The dense-GEMM-on-FP16-tensor-cores change that used to live here was retired at
  # an earlier bump: upstream 0.1.39+ has the same path natively (bf16_path() in
  # gemm.cu, #540/#655) and the module now selects it with upstream's STRATA_BF16_TC=1.
  # The refill rework (the resolve/plans pass, STRATA_DMA_BATCH, adapt_copy_h2d,
  # blob_stable, the AMD pin_blobs) is upstream's and is kept by the patch.
  # The host expert tier is NOT here any more: upstream has it natively
  # (--resident-budget-gib N, used by profiles/nixos/strata.nix).
  # no-web-ui.patch is the serve layer: STRATA_NO_WEB=1 turns the bundled web
  # app's pages, assets and /settings into 404s and leaves the API untouched.
  # All three were regenerated against the pin above for the v0.2.12 bump and
  # re-applied in order onto a pristine v0.2.12 tree (bit-identical result) before
  # this build.  tiberius.patch had been regenerated on 2026-11-04 for the
  # transactional-park addition (built, probed and deployed as generation 101), once
  # more for STRATA_DAX_TIMING (deployed as generation 102) and once more for the
  # streamed session restore + draft-optional SAVE/RESTORE (deployed as generation
  # 103), each time re-verified the same way.  The module's run config does not change: the timing
  # is log-only and off unless STRATA_DAX_TIMING=1 is set, which is exactly how the
  # task-8 A/B measured the rotation cost.
  #
  # avx512-bw-tier.patch is the COMPILE-TIME half of the AVX-512 expert tier on
  # VBMI-less CPUs.  0.2.12 upstreamed the run-time half (PR 5120, f000d4a4 +
  # 7e3fae57: cpu_vbmi_ok / cpu_vnni_ok / q2_rows_512_ok in expert_layout.{hpp,cpp},
  # the VBMI-free q2 unpack in expert.cpp, and the call sites that select it) and
  # makes the tier OPT-IN below VBMI through STRATA_VNNI_TIER=1; the module sets that
  # variable (profiles/nixos/strata.nix), so this box keeps the 512-bit tier the
  # patch used to force.  The gate split, the gate renames and the call-site hunks
  # are GONE from this patch - they were upstreamed, and carrying them again would
  # duplicate or shadow upstream's own probes.
  # What remains is what a run-time branch cannot promise: the compiler may still
  # emit VBMI code in a TU built with -mavx512vbmi (the SIGILL class in
  # VALIDATION.md).  So expert.cpp's two 2-bit unpacks are made VBMI-free
  # unconditionally with tiberius's substitute (VPERMW + VPSRLVW + VPMOVWB,
  # byte-identical to VPMULTISHIFTQB, layout-verified exhaustively against a scalar
  # reference), and -mavx512vbmi is removed from expert.cpp and from iq_avx512.cpp +
  # nvfp4_avx512.cpp in the CPU backend's flag lists (cmake/backends/cpu.cmake since
  # the 0.2.13 build split; the root CMakeLists.txt holds none) and in
  # sycl/CMakeLists.txt, while tq_avx512.cpp keeps
  # the flag and the original cpu_avx512_ok() gate - weakening that one instead would
  # let this Cascade Lake part execute VBMI trellis code.
  # Measured on tiberius 2026-10-12 (ab18 campaign, 3 counterbalanced runs per arm):
  # ~5 % cheaper CPU expert pool+plan per decode window, GPU wait and Optane reads
  # unchanged, outputs numerically sound (parity 0 failures vs the ggml references)
  # but NOT bit-identical to the AVX-2 tier on the long cells.
  # See docs/exec-plans/active/tiberius-kernel-tuning.md.
  patches = [
    ./tiberius.patch
    ./no-web-ui.patch
    ./avx512-bw-tier.patch
  ];

  # The module's env carries this patch's STRATA_REGISTER_DAX(+_MIB),
  # STRATA_DAX_TIMING and STRATA_REFILL_PIN_SRC, upstream's STRATA_BF16_TC and
  # STRATA_VNNI_TIER (the CPU-tier opt-in described above), and the rest of the
  # lane's measured settings; hostTierGib > 0 selects upstream's resident RAM tier
  # instead of --mmap-experts.  Upstream treats an unknown flag as fatal: a patch
  # that silently failed to apply would turn the whole service into a crash-loop,
  # and a silently missing window would drop the measured prefill win without
  # saying so.  Fail the build here instead.
  postPatch = ''
    grep -q 'STRATA_NO_WEB' serve/server.py || {
      echo "no-web-ui.patch did not introduce the STRATA_NO_WEB gate" >&2
      exit 1
    }
    grep -q 'resident-budget-gib' src/program/generate.cpp || {
      echo "the engine source has no --resident-budget-gib (upstream's resident tier)" >&2
      exit 1
    }
    grep -q 'STRATA_REGISTER_DAX' src/core/expert_source.cpp || {
      echo "tiberius.patch did not introduce the STRATA_REGISTER_DAX sliding window" >&2
      exit 1
    }
    grep -q 'STRATA_BF16_TC' src/prefill/gemm.cu || {
      echo "the engine no longer reads STRATA_BF16_TC (the dense FP16 tensor-core path)" >&2
      exit 1
    }
    grep -q 'STRATA_REFILL_PIN_SRC' src/program/generate.cpp || {
      echo "tiberius.patch did not introduce the STRATA_REFILL_PIN_SRC refill path" >&2
      exit 1
    }
    # Every other env var the module sets must still be consumed at the pinned
    # revision.  Upstream ignores unknown env vars silently, so a rebase that
    # dropped one would change serving behaviour with no build failure.
    grep -q 'STRATA_SPLIT_TIMING' src/program/generate.cpp || {
      echo "the engine no longer reads STRATA_SPLIT_TIMING (serve stage timing)" >&2
      exit 1
    }
    grep -q 'STRATA_KV_ROT' src/program/generate.cpp || {
      echo "the engine no longer reads STRATA_KV_ROT (the rotated int8 KV the module selects)" >&2
      exit 1
    }
    # hostTierGib > 0 turns upstream's resident RAM tier back on; the deployed lane
    # runs hostTierGib = 0 (--mmap-experts) and the module does not set these two,
    # but keep upstream's knobs present so that option's behaviour cannot change
    # under it silently.
    grep -q 'STRATA_RESIDENT_PIN' src/program/generate.cpp || {
      echo "the engine no longer reads STRATA_RESIDENT_PIN (the resident RAM tier's pin knob)" >&2
      exit 1
    }
    grep -q 'STRATA_RESIDENT_HEADROOM_GIB' src/program/generate.cpp || {
      echo "the engine no longer reads STRATA_RESIDENT_HEADROOM_GIB (the resident RAM tier's headroom knob)" >&2
      exit 1
    }
    grep -q 'STRATA_UNBUFFERED_LOAD' src/core/expert_source.cpp || {
      echo "the engine no longer reads STRATA_UNBUFFERED_LOAD (the file tier's page-cache arm)" >&2
      exit 1
    }
    grep -q 'STRATA_STAGER_RING' src/prefill/prefill.cpp || {
      echo "the engine no longer reads STRATA_STAGER_RING (the measured staging ring)" >&2
      exit 1
    }
    grep -q 'STRATA_PREFILL_CPU_SHARE' src/prefill/prefill.cpp || {
      echo "the engine no longer reads STRATA_PREFILL_CPU_SHARE (the module pins the CPU share off)" >&2
      exit 1
    }
    grep -q 'STRATA_ROUTE_TAIL_SKIP' src/program/generate.cpp || {
      echo "the engine no longer reads STRATA_ROUTE_TAIL_SKIP (the measured decode default)" >&2
      exit 1
    }
    grep -q 'STRATA_PCIE_FRAC_DEFAULT' src/program/generate.cpp || {
      echo "the engine no longer reads STRATA_PCIE_FRAC_DEFAULT (the pinned start-up share)" >&2
      exit 1
    }
    # 0.2.11's discrete-CUDA CPU/upload share rule (pcie_share_rule.hpp, ceiling
    # 0.95 with k following the pool rate) feeds PcieAuto only, and the module's
    # STRATA_PCIE_FRAC_DEFAULT=old keeps that refinement off.  Fail here if the
    # gates disappear, so a later bump cannot silently hand this lane's share to
    # the new rule (it moved the share up and cost 5-7% decode when measured on
    # this box in the 0.1.42 campaigns).
    for v in STRATA_PCIE_AUTO_SPLIT STRATA_PCIE_K_RULE STRATA_PCIE_SHARE_MAX; do
      grep -q "$v" src/program/generate.cpp || {
        echo "the engine no longer reads $v (the 0.2.11 CPU/upload share gates)" >&2
        exit 1
      }
    done

    # The old pin must keep PcieAuto off on this box: the start-up gate is
    # `o.pcie_frac_auto = ... && !pf_old`.  A rebase that re-enables the
    # refinement (or renames the gate) changes this lane's decode share - fail
    # the build instead of accepting it silently.
    grep -A3 'o.pcie_frac_auto = ' src/program/generate.cpp | grep -q '!pf_old' || {
      echo "the STRATA_PCIE_FRAC_DEFAULT=old gate no longer disables PcieAuto" >&2
      exit 1
    }
    # 0.2.11's FP16 weight cache is a value-changing default that selects only
    # with batch slots (--batch/--parallel >= 2); this lane runs none.  Keep the
    # gate, so a later default cannot move this card's outputs.
    grep -q 'set_w16_auto_default' src/program/generate.cpp && grep -q 'o.batch >= 2' src/program/generate.cpp || {
      echo "the FP16 weight cache is no longer gated on batch slots (o.batch >= 2)" >&2
      exit 1
    }
    # 0.2.11's 32768-token --prefill auto ceiling is compute capability 8.0+ only
    # and this lane passes an explicit --prefill; keep the bare-auto gate present
    # so a later bump cannot silently raise this lane's chunk.
    grep -q 'prefill_auto_bare' src/program/generate.cpp || {
      echo "the --prefill auto ceiling gate (prefill_auto_bare) disappeared" >&2
      exit 1
    }
    # 0.2.11's K-quant MMQ prompt kernels are compute capability 8.0+ only; the
    # sm_75 build must keep the variable behind nv_defaults.cpp's cc gate.
    grep -q 'STRATA_MMQ_KQ' src/core/nv_defaults.cpp || {
      echo "the K-quant MMQ default gate (STRATA_MMQ_KQ) disappeared from nv_defaults.cpp" >&2
      exit 1
    }
    # The module's `--kv-resident 0` user arg keeps 0.2.11's fit_start from
    # injecting a KV window (which would turn --kv-grow off).  The fitter's
    # kv_fixed path is the hook; fail if it disappears.
    grep -q 'kv_fixed' strata_control/vram_fit.py || {
      echo "vram_fit lost the kv_fixed hook (the module's --kv-resident 0 workaround)" >&2
      exit 1
    }
    grep -q 'STRATA_REGISTER_DAX_MIB' src/core/expert_source.cpp || {
      echo "tiberius.patch lost the STRATA_REGISTER_DAX_MIB window budget" >&2
      exit 1
    }
    # tiberius.patch's env-gated per-rotation DAX timing (log-only, off by default).  It is the only
    # place the window rotation's cost is attributed, so a rebase that drops it silently would take the
    # measurement seam with it - fail here instead.
    grep -q 'STRATA_DAX_TIMING' src/core/expert_source.cpp || {
      echo "tiberius.patch lost the per-rotation DAX timing (STRATA_DAX_TIMING)" >&2
      exit 1
    }
    # tiberius.patch's transactional park: the distinct refusal line is its marker (no upstream line has
    # these words).  A rebase that drops the pre-check but keeps the old eviction loop must fail the build
    # here rather than silently bring back the destructive refusal.
    grep -q 'nothing evicted' src/program/generate.cpp || {
      echo "tiberius.patch lost the transactional-park pre-check in park_source()" >&2
      exit 1
    }
    grep -q 'evictable_bytes' include/strata/core/conversation_cache.hpp || {
      echo "tiberius.patch lost the ConversationCache::evictable_bytes() pre-check helper" >&2
      exit 1
    }
    # tiberius.patch's streamed session restore (round 5): the API name and the pass-1/pass-2 marker strings.  A
    # rebase that drops the streaming would silently go back to the whole-image read, which refuses the 250k session.
    grep -q 'session_file_restore_streamed' src/program/generate.cpp || {
      echo "tiberius.patch lost the streamed session restore (generate.cpp)" >&2
      exit 1
    }
    grep -q 'SessionStreamMeta' include/strata/core/conversation_file.hpp || {
      echo "tiberius.patch lost SessionStreamMeta (the streamed restore's metadata pass)" >&2
      exit 1
    }
    grep -q "drafter's position/tags" src/program/generate.cpp || {
      echo "tiberius.patch lost the DFlash2 invalidate-after-restore" >&2
      exit 1
    }
    # tiberius.patch's pmem park-spill file tier (round 7): the option, the tier class and its log marker.  A rebase
    # that drops the fallback would silently go back to refusing the park (the long-conversation re-read).
    grep -q 'conversation-park-dir' src/program/generate.cpp || {
      echo "tiberius.patch lost the --conversation-park-dir option" >&2
      exit 1
    }
    grep -q 'ConversationParkFiles' include/strata/core/conversation_park_file.hpp || {
      echo "tiberius.patch lost the ConversationParkFiles file tier" >&2
      exit 1
    }
    grep -q 'tokens to pmem in' src/program/generate.cpp || {
      echo "tiberius.patch lost the park-to-pmem write path / its log marker" >&2
      exit 1
    }
    grep -q 'restore_park_file' src/program/generate.cpp || {
      echo "tiberius.patch lost the request-path pmem park restore" >&2
      exit 1
    }
    # tiberius.patch's pmem park checkpoint match (round 8): the saved-checkpoint selection and its debug
    # instrumentation.  A rebase that drops them brings back the full-reread after an ordinary-turn park.
    grep -q 'STRATA_PARK_DEBUG' src/program/generate.cpp || {
      echo "tiberius.patch lost the pmem park debug instrumentation (STRATA_PARK_DEBUG)" >&2
      exit 1
    }
    grep -q 'saved_tokens' include/strata/core/conversation_park_file.hpp || {
      echo "tiberius.patch lost the pmem park saved-checkpoint matching" >&2
      exit 1
    }
    # round 8b: the CUDA stop_bound port and its telemetry, and the server-side WSTAT counters.
    grep -q 'STRATA_SERVE_STOP_BOUND' src/program/generate.cpp || {
      echo "tiberius.patch lost the stop bound (STRATA_SERVE_STOP_BOUND)" >&2
      exit 1
    }
    grep -q 'WSTAT rot=' src/program/generate.cpp || {
      echo "tiberius.patch lost the per-request WSTAT telemetry line" >&2
      exit 1
    }
    grep -q 'prefill_last_phase_times' include/strata/prefill/prefill.hpp || {
      echo "tiberius.patch lost the prefill phase timeline accessor" >&2
      exit 1
    }
    grep -q 'verify_window_tokens' serve/prometheus.py || {
      echo "tiberius.patch lost the /metrics/prometheus WSTAT counters" >&2
      exit 1
    }
    grep -q '_last_wstat' serve/server.py || {
      echo "tiberius.patch lost the WSTAT stash that survives the DONE parse" >&2
      exit 1
    }
    # Upstream's surface since v0.1.42 (its take of PR #1283, a26fcbcd): the `src`
    # argument the prompt-path sizing takes, and that tiberius.patch's call sites use.
    grep -q 'bool src' include/strata/prefill/prefill.hpp || {
      echo "the bytes_needed signatures no longer take src" >&2
      exit 1
    }
    # the RTX 20 kernel series the perf campaign selects.  It lives in a header
    # upstream owns; a rebase that drops it must fail here rather than silently
    # turning STRATA_SM75_PERF into an ignored variable.
    grep -q 'STRATA_SM75_PERF' include/strata/core/sm75_series.hpp || {
      echo "the engine no longer has the Turing kernel series (STRATA_SM75_PERF)" >&2
      exit 1
    }
    # avx512-bw-tier.patch keeps the compile-time half of the AVX-512 tier on a
    # VBMI-less CPU (0.2.12 supplies the run-time gate split: cpu_vnni_ok() and the
    # VBMI-free q2 unpack in expert.cpp).  The module sets STRATA_VNNI_TIER=1, which
    # is what lets upstream's cpu_vnni_ok() admit this Cascade Lake part; the absence
    # checks and the flag checks below are then the SIGILL guard - a VPMULTISHIFTQB
    # unpack, or any VBMI code a -mavx512vbmi TU could emit, would execute on this
    # box (the failure class in VALIDATION.md).  The trellis TU must keep both its
    # VBMI flag and the original gate.  Patterns are precise so they cannot match
    # the explanatory comments the patch itself adds.
    grep -q 'STRATA_VNNI_TIER' src/kernels/cpu/expert_layout.cpp || {
      echo "upstream's VBMI-less CPU tier no longer reads STRATA_VNNI_TIER (the module's expert-tier opt-in)" >&2
      exit 1
    }
    if grep -q 'multishift_epi64_epi8' src/kernels/cpu/expert.cpp; then
      echo "avx512-bw-tier.patch did not remove the VPMULTISHIFTQB 2-bit unpacks" >&2
      exit 1
    fi
    grep -q '_mm512_srlv_epi16' src/kernels/cpu/expert.cpp || {
      echo "avx512-bw-tier.patch did not introduce the VBMI-free unpack" >&2
      exit 1
    }
    # 0.2.13 split the monolithic CMakeLists.txt: the per-TU kernel flag lists
    # now live in cmake/backends/cpu.cmake (moved verbatim; the root file keeps
    # none).  The sycl build keeps its own three lists in sycl/CMakeLists.txt.
    # The ;-delimited form is used there because the patched iq/nvfp4 flag line
    # carries a trailing comment that mentions -mavx512vbmi by name.
    if grep -A1 'src/kernels/cpu/expert.cpp' cmake/backends/cpu.cmake | grep -q -- '-mavx512vbmi'; then
      echo "avx512-bw-tier.patch left -mavx512vbmi on expert.cpp" >&2
      exit 1
    fi
    if grep -A1 'iq_avx512.cpp src/kernels/cpu/nvfp4_avx512.cpp' cmake/backends/cpu.cmake | grep -q -- '-mavx512vbmi'; then
      echo "avx512-bw-tier.patch left -mavx512vbmi on iq/nvfp4_avx512.cpp" >&2
      exit 1
    fi
    grep -A1 'src/kernels/cpu/tq_avx512.cpp PROPERTIES' cmake/backends/cpu.cmake | grep -q -- '-mavx512vbmi' || {
      echo "avx512-bw-tier.patch dropped VBMI from the trellis TU (its gate requires it)" >&2
      exit 1
    }
    if grep -A1 'cpu/expert.cpp' sycl/CMakeLists.txt | grep -q -- ';-mavx512vbmi;'; then
      echo "avx512-bw-tier.patch left -mavx512vbmi on expert.cpp (sycl)" >&2
      exit 1
    fi
    if grep -A1 'cpu/iq_avx512.cpp' sycl/CMakeLists.txt | grep -q -- ';-mavx512vbmi;'; then
      echo "avx512-bw-tier.patch left -mavx512vbmi on iq/nvfp4_avx512.cpp (sycl)" >&2
      exit 1
    fi
    grep -A1 'src/kernels/cpu/tq_avx512.cpp PROPERTIES' sycl/CMakeLists.txt | grep -q -- ';-mavx512vbmi;' || {
      echo "avx512-bw-tier.patch dropped VBMI from the trellis TU (sycl)" >&2
      exit 1
    }
    grep -q 'cpu_avx512_ok' src/kernels/cpu/tq_cpu.cpp || {
      echo "the trellis kernel no longer uses the VBMI gate" >&2
      exit 1
    }
    # 0.2.13's two build-resolution facts this package now relies on: the ggml the
    # engine links is the vendored tree (third_party/strata-ggml at the llama.cpp pin
    # above, so the derivation fetches no llama.cpp), and the model shape is compiled
    # in at configure time with flash_next - the shape this lane serves - as the
    # default.  A later bump that moved either silently would build an engine for
    # another shape or against another ggml; fail here instead.
    grep -q '3cf03257f219afbe7334045ff7c6a06ac68c627d' third_party/strata-ggml/UPSTREAM.md || {
      echo "the vendored ggml is no longer at llama.cpp 3cf03257 (the package pins it)" >&2
      exit 1
    }
    grep -q 'set(STRATA_GEOMETRY "flash_next"' cmake/strata_geometry.cmake || {
      echo "the compiled-geometry default is no longer flash_next (this lane serves flash_next)" >&2
      exit 1
    }
  '';

  nativeBuildInputs = [
    cmake
    ninja
  ];

  buildInputs = [
    c.cuda_cudart
    c.libcublas
    c.cuda_cccl
  ];

  env = {
    CUDA_HOME = cudaHome;
    CUDA_PATH = cudaHome;
    CUDAToolkit_ROOT = cudaHome;
    CUDACXX = "${cudaHome}/bin/nvcc";
    CPATH = "${cudaHome}/include";
    CPLUS_INCLUDE_PATH = "${cudaHome}/include";
    LIBRARY_PATH = "${cudaHome}/lib";
    # ggml-cpu's x86 repack/quants translation units are built with
    # -march=native; nixpkgs' cc-wrapper silently drops it (NIX_ENFORCE_NO_NATIVE,
    # 15 "Skipping impure flag" warnings in the build log), which leaves __AVX2__ /
    # __AVX512F__ undefined there and compiles llama.cpp's IQ/Q2_K/Q4_K AVX GEMMs
    # to 5-byte stubs (nm: ggml_gemm_q2_K_8x8_q8_K 5 B vs 44695 B once kept).
    # Measured 2026-10-03 on this box (/data/bldflags): the store binary decoded
    # 6.10% (4292-token prompt) / 11.13% (27523) slower than the same source built
    # locally, and clearing this flag recovers all of it; hardening, CUDA 12.9 vs
    # 13.2, glibc and PIE each move <1%, and IPO/LTO costs 9.4%.  tiberius is a
    # single known host (Xeon Gold 6246), so a native -march is what we want; if
    # this package is ever built for another CPU, pass -DGGML_NATIVE=OFF instead.
    NIX_ENFORCE_NO_NATIVE = "0";
  };

  cmakeFlags = [
    "-DSTRATA_ENABLE_CUDA=ON"
    "-DSTRATA_BUILD_TESTS=OFF"
    "-DCMAKE_CUDA_ARCHITECTURES=75"
    "-DCMAKE_CUDA_COMPILER=${cudaHome}/bin/nvcc"
  ];

  installPhase = ''
    runHook preInstall
    src="$NIX_BUILD_TOP/$sourceRoot"
    [ -d "$src" ] || src="$sourceRoot"
    mkdir -p $out/bin $out/share/strata
    install -m755 "$(find . -maxdepth 2 -type f -name strata | head -1)" $out/bin/strata
    # server.py imports strata_control at module load (engine_component, tls,
    # hipblaslt_tuning, vision_reader, draft_layer, drafting, user_args,
    # gpu_roles), and strata_control.models resolves data/ relative to the
    # package root.  A service built without either dies at import time.
    cp -r "$src/serve" "$src/tools" "$src/strata_control" $out/share/strata/
    mkdir -p $out/share/strata/data
    install -m644 "$src/data/expert-profile.bin" $out/share/strata/data/
    install -m644 "$src/data/expert-profile-coder.bin" $out/share/strata/data/
    install -m644 "$src/data/gguf_fingerprints.json" $out/share/strata/data/
    runHook postInstall
  '';

  meta = with lib; {
    description = "Strata inference engine (Qwen3.8-Flash-Next, CUDA sm_75)";
    homepage = "https://github.com/Niko1221/Strata";
    license = licenses.mit;
    platforms = [ "x86_64-linux" ];
    mainProgram = "strata";
  };
}
