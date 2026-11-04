{
  lib,
  stdenv,
  fetchFromGitHub,
  fetchzip,
  cmake,
  ninja,
  cudaPackages,
  symlinkJoin,
}:

# The Strata engine, built for Turing (sm_75) from the pinned source revision.
#
# The pin is the whole stack: the engine source, the llama.cpp/ggml revision the
# CMake build links (`STRATA_GGML_DIR`), and the CUDA toolkit.  Only the engine is
# built here -- the model files (pack, experts.bin, PLE GGUF, MTP) are prepared
# once on the host by the setup flow and live on /optane, not in the store.
#
# tiberius: CUDA 12.9 from nixpkgs, sm_75 only.  The 22 GB RTX 2080 Ti runs the
# engine with --mmap-experts, so this build only needs the sm_75 i-quant kernels
# and the driver's libcuda.so.1 at runtime (the module adds it to the service's
# LD_LIBRARY_PATH).
let
  c = cudaPackages;

  # ffa80d73: v0.2.10 (2026-11-02), the current release.  The engine inside it
  # is 0.1.56.  Since the last pin (c62d5e3a = v0.2.9 / engine 0.1.55) upstream's
  # headline changes are the DFlash2 drafter (the Auto choice for Qwen3.8 on CUDA
  # compute capability 8.6/8.9/12.0/12.1 - sm_75 is NOT in that list, so this
  # lane keeps the MTP layer it has), the all-cards split engine (Auto only for
  # two 8.6/12.0 cards or four R9700s; one card keeps the layer split), the
  # 128K-context walk for 8 GB cards, the ISTA-DAS Coder and DeepSeek pictures on
  # a Mac.  None of those select for a single 22 GB sm_75 card; what does reach
  # this lane is the 0.1.56 engine itself: the Qwen penalty window now counts
  # only the reply's own tokens (#4590; the old whole-prompt window is
  # STRATA_PENALTY_PROMPT=1 - a documented answer change, adopted), and the PLE
  # lock path raises the memlock soft limit before locking (#4671) - not
  # exercised here: --ple-io mmap leaves the table mapped and unlocked (only
  # --ple-io ram or the residency policy sets pio.lock).  NOT this lane: #4677's
  # stop-bound park fix is compiled only under STRATA_USE_HIP (generate.cpp
  # defines `stop_bound` and both call sites inside the HIP guard), so this CUDA
  # build carries neither the behaviour nor STRATA_SERVE_STOP_BOUND.  One new
  # serve-layer trap: 0.2.10's
  # vram_fit.fit_start runs on every engine start and on CUDA its only knob is
  # --kv-resident; the engine turns --kv-grow off whenever a KV window is set,
  # so a start the fitter calls short would silently drop the module's measured
  # elastic-KV win - watch for the "KV window ..." line in the journal.
  # llama.cpp's pin is unchanged (third_party/ggml/VERSION.txt = 3cf03257), so
  # llamaRevision below still holds.
  revision = "ffa80d73133ea5c548aefe57889a16e8085a938f";
  llamaRevision = "3cf03257f219afbe7334045ff7c6a06ac68c627d";

  llama = fetchzip {
    url = "https://github.com/ggml-org/llama.cpp/archive/${llamaRevision}.zip";
    hash = "sha256-SRGoXa+4ACBCB3eaG9XFYhMN1i0FyPEy9Rrer+dFGYI=";
  };

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
  version = "0.1.56";

  # The build host's CPU decides the codegen (NIX_ENFORCE_NO_NATIVE is cleared
  # below, and ggml compiles with -march=native).  tiberius's nix.conf lists
  # pius (an AVX2-only i5-8400) and trajanus (Zen 4) as builders, so a plain
  # nix build dispatches this derivation and the result carries the BUILDER's
  # instructions.  Measured 2026-10-11: the trajanus and pius builds of the
  # same drv differ in 50,132,344 bytes, and two instruction classes show up:
  #   * the engine's own AVX-512 expert kernels (expert.cpp) are built for
  #     F/DQ/BW/VL/VNNI and selected at run time by cpu_avx512_vnni_ok() (the
  #     VBMI-free gate avx512-bw-tier.patch adds; the trellis TU keeps the
  #     VBMI-requiring cpu_avx512_ok()).  Before that patch the shared gate
  #     demanded VBMI too, which made the expert tier dead code here and printed
  #     "this CPU has no AVX-512: the expert kernels run on AVX-2" in every
  #     deployment log; with the split gate the expert tier is TRUE on this CPU
  #     and executes - the built object has 0 vpmultishiftqb and 492 vpsrlvw.
  #     Measured 2026-10-12 (ab18 campaign, 3 counterbalanced runs per arm):
  #     ~5 % cheaper CPU expert pool+plan per decode window, prefill and the
  #     Optane reads unchanged;
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
    hash = "sha256-cIBcdKRYVH78bu4sElF0XK/wedcLTK8tu12c0Alzlw8=";
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
  #     gv3vlx7ah...).  Accepted follow-ups for the next regeneration: the four "payload
  #     ends early" over-read guards dropped in this cut and conversation_file.cpp's
  #     final newline.  See /tmp/strata-tune/stream-restore-design.md and -results.md.
  # The dense-GEMM-on-FP16-tensor-cores change that used to live here was retired at
  # an earlier bump: upstream 0.1.39+ has the same path natively (bf16_path() in
  # gemm.cu, #540/#655) and the module now selects it with upstream's STRATA_BF16_TC=1.
  # The refill rework (the resolve/plans pass, STRATA_DMA_BATCH, adapt_copy_h2d,
  # blob_stable, the AMD pin_blobs) is upstream's and is kept by the patch.
  # The host expert tier is NOT here any more: upstream has it natively
  # (--resident-budget-gib N, used by profiles/nixos/strata.nix).
  # no-web-ui.patch is the serve layer: STRATA_NO_WEB=1 turns the bundled web
  # app's pages, assets and /settings into 404s and leaves the API untouched.
  # All three were generated against the pin above and re-applied in order onto a
  # pristine ffa80d73 tree (bit-identical result) before this build.  tiberius.patch
  # was regenerated again on 2026-11-04 for the transactional-park addition (built,
  # probed and deployed as generation 101), once more for STRATA_DAX_TIMING (deployed
  # as generation 102) and once more for the streamed session restore + draft-optional
  # SAVE/RESTORE (deployed as generation 103), each time re-verified the same way.  The module's run config does not change: the timing
  # is log-only and off unless STRATA_DAX_TIMING=1 is set, which is exactly how the
  # task-8 A/B measured the rotation cost.
  #
  # avx512-bw-tier.patch is the AVX-512 expert tier on VBMI-less CPUs.  It
  # replaces the two VPMULTISHIFTQB 2-bit unpacks with an equivalent
  # VPERMW + VPSRLVW + VPMOVWB form (layout-verified exhaustively against a
  # scalar reference), removes `-mavx512vbmi` from the expert and i-quant
  # translation units, and SPLITS the run-time gate: the expert/iq/nvfp4 kernels
  # use the new cpu_avx512_vnni_ok() (F/DQ/BW/VL/VNNI, no VBMI), while the
  # trellis kernel keeps the original cpu_avx512_ok() (which still requires
  # VBMI, matching tq_avx512.cpp's flags).  Weakening the shared gate instead
  # would let this Cascade Lake part execute VBMI trellis code - the SIGILL class
  # in VALIDATION.md.  Measured on tiberius 2026-10-12 (ab18 campaign, 3
  # counterbalanced runs per arm): ~5 % cheaper CPU expert pool+plan per decode
  # window, GPU wait and Optane reads unchanged, outputs numerically sound
  # (parity 0 failures vs the ggml references) but NOT bit-identical to the
  # AVX-2 tier on the long cells.
  # See docs/exec-plans/active/tiberius-kernel-tuning.md.
  patches = [
    ./tiberius.patch
    ./no-web-ui.patch
    ./avx512-bw-tier.patch
  ];

  # The module passes --resident-budget-gib and sets STRATA_REGISTER_DAX and
  # STRATA_REFILL_PIN_SRC (both the patch's; STRATA_BF16_TC is upstream's).  Upstream
  # treats an unknown flag as fatal: a patch that silently failed to apply would turn
  # the whole service into a crash-loop, and a silently missing window would drop the
  # measured prefill win without saying so.  Fail the build here instead.
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
    grep -q 'STRATA_RESIDENT_PIN' src/program/generate.cpp || {
      echo "the engine no longer reads STRATA_RESIDENT_PIN (the module keeps the host tier pageable)" >&2
      exit 1
    }
    grep -q 'STRATA_RESIDENT_HEADROOM_GIB' src/program/generate.cpp || {
      echo "the engine no longer reads STRATA_RESIDENT_HEADROOM_GIB" >&2
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
    # avx512-bw-tier.patch splits the AVX-512 gate.  The absence checks are the
    # SIGILL guard: if an unpack or a VBMI flag survives in a VBMI-free kernel
    # while cpu_avx512_vnni_ok() admits this Cascade Lake part, the engine would
    # execute VBMI (the failure class in VALIDATION.md).  The trellis TU must
    # keep both its VBMI flag and the original gate.  Patterns are precise so
    # they cannot match the explanatory comments the patch itself adds.
    grep -q 'cpu_avx512_vnni_ok' include/strata/kernels/cpu/expert_layout.hpp || {
      echo "avx512-bw-tier.patch did not add the VBMI-free gate" >&2
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
    if grep -A1 'src/kernels/cpu/expert.cpp' CMakeLists.txt | grep -q -- '-mavx512vbmi'; then
      echo "avx512-bw-tier.patch left -mavx512vbmi on expert.cpp" >&2
      exit 1
    fi
    if grep -A1 'iq_avx512.cpp src/kernels/cpu/nvfp4_avx512.cpp' CMakeLists.txt | grep -q -- '-mavx512vbmi'; then
      echo "avx512-bw-tier.patch left -mavx512vbmi on iq/nvfp4_avx512.cpp" >&2
      exit 1
    fi
    grep -A1 'src/kernels/cpu/tq_avx512.cpp PROPERTIES' CMakeLists.txt | grep -q -- '-mavx512vbmi' || {
      echo "avx512-bw-tier.patch dropped VBMI from the trellis TU (its gate requires it)" >&2
      exit 1
    }
    grep -q 'cpu_avx512_ok' src/kernels/cpu/tq_cpu.cpp || {
      echo "the trellis kernel no longer uses the VBMI gate" >&2
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
    "-DSTRATA_GGML_DIR=${llama}"
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
