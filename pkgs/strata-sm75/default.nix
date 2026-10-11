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

  # 61b3fb5d: v0.1.42 (2026-10-10), the release with the new CUDA defaults the module
  # measures before adopting (STRATA_ROUTE_TAIL_SKIP=7 on this shape, the CPU-measured
  # PCIe share; see profiles/nixos/strata.nix).  v0.1.41 (fb58e0d) is an ancestor of
  # this tag; upstream rewrote its history before v0.1.40.2, so older pins are not.
  revision = "61b3fb5dd3f1e8ec09cf7e4e05208bc6d3c46406";
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
  version = "0.1.42";

  # The build host's CPU decides the codegen (NIX_ENFORCE_NO_NATIVE is cleared
  # below, and ggml compiles with -march=native).  tiberius's nix.conf lists
  # pius (an AVX2-only i5-8400) and trajanus (Zen 4) as builders, so a plain
  # nix build dispatches this derivation and the result carries the BUILDER's
  # instructions.  Measured 2026-10-11: the trajanus and pius builds of the
  # same drv differ in 50,132,344 bytes, and two instruction classes show up:
  #   * the engine's own AVX-512 expert kernels (expert.cpp) are compiled with
  #     explicit -mavx512f/bw/vl/dq/vnni/vbmi (CMake, on every build) and
  #     selected at run time by cpu_avx512_ok() = F+BW+VL+VNNI+VBMI; that gate
  #     is FALSE on this CPU (the deployed log reads "this CPU has no AVX-512:
  #     the expert kernels run on AVX-2"), so the 296 vpmultishiftqb in
  #     q2g_row_multi never execute - dead by design, in every build;
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
    hash = "sha256-FPwm4cuGTFiXgWkK5eTcfD9VIrH/OnVZiG6ToQFOfMQ=";
  };

  # carry-1283.patch is GONE at this pin: upstream took PR #1283 (commit a26fcbcd,
  # released in v0.1.42), so tiberius.patch is regenerated against 61b3fb5 directly
  # and no longer sits on the carry's tree.
  #
  # tiberius.patch is tiberius's local engine changes, in one patch because they
  # interleave in the same regions of expert_source.{hpp,cpp}, prefill.{hpp,cpp}
  # and generate.cpp:
  #   * the STRATA_REGISTER_DAX sliding window, which makes the layer the prefill is
  #     reading DMA-able by the device without registering the whole 46.84 GiB pack;
  #   * STRATA_REFILL_PIN_SRC, the decode-time VRAM refill read from registered sources,
  #     with its straddle guard.
  # The dense-GEMM-on-FP16-tensor-cores change that used to live here was retired at
  # this bump: upstream 0.1.39+ has the same path natively (bf16_path() in gemm.cu,
  # #540/#655) and the module now selects it with upstream's STRATA_BF16_TC=1.
  # The 0.1.40.x refill rework (the resolve/plans pass, STRATA_DMA_BATCH,
  # adapt_copy_h2d, the AMD pin_blobs) is upstream's and is kept by the patch.
  # The host expert tier is NOT here any more: upstream has it natively
  # (--resident-budget-gib N, used by profiles/nixos/strata.nix).
  # no-web-ui.patch is the serve layer: STRATA_NO_WEB=1 turns the bundled web
  # app's pages, assets and /settings into 404s and leaves the API untouched.
  # Both were regenerated against the pin above, so `patch -p1` applies cleanly.
  patches = [
    ./tiberius.patch
    ./no-web-ui.patch
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
    # Upstream's surface since v0.1.42 (its take of PR #1283, a26fcbcd): the `src`
    # argument the prompt-path sizing takes, and that tiberius.patch's call sites use.
    grep -q 'bool src' include/strata/prefill/prefill.hpp || {
      echo "the bytes_needed signatures no longer take src" >&2
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
    cp -r "$src/serve" "$src/tools" $out/share/strata/
    mkdir -p $out/share/strata/data
    install -m644 "$src/data/expert-profile.bin" $out/share/strata/data/
    install -m644 "$src/data/expert-profile-coder.bin" $out/share/strata/data/
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
