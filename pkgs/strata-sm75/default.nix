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

  revision = "d6708a4aae15b4860000d54c8af9e84d684bce09";
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
  version = "0.1.29";

  src = fetchFromGitHub {
    owner = "Niko1221";
    repo = "Strata";
    rev = revision;
    hash = "sha256-Unkpm1Wj7qtvZA/uKvm4tJFOUPYOPhCdvoVn9u17xXc=";
  };

  # tiberius's two local engine changes, in one patch because they edit the same
  # regions of expert_source.{hpp,cpp} and generate.cpp:
  #   * the host expert tier -- a rank-ordered, size-capped DRAM complement
  #     (--resident-cpu-experts --resident-cpu-mib N) plus the relaxed requirement
  #     that let it coexist with the adaptive VRAM cache;
  #   * the STRATA_REGISTER_DAX sliding window, which makes the layer the prefill
  #     is reading DMA-able by the device without registering the whole 46.84 GiB pack.
  # Same source revision as the pin above, so `patch -p1` applies cleanly.
  patches = [ ./tiberius.patch ];

  # The service passes --resident-cpu-mib and sets STRATA_REGISTER_DAX, and both
  # exist only because the patch above adds them.  Upstream treats an unknown flag
  # as fatal, so a patch that silently failed to apply would turn the whole service
  # into a crash-loop -- and a silently missing window would drop the measured
  # prefill win without saying so.  Fail the build here instead.
  postPatch = ''
    grep -q 'resident-cpu-mib' src/program/generate.cpp || {
      echo "tiberius.patch did not introduce --resident-cpu-mib" >&2
      exit 1
    }
    grep -q 'STRATA_REGISTER_DAX' src/core/expert_source.cpp || {
      echo "tiberius.patch did not introduce the STRATA_REGISTER_DAX sliding window" >&2
      exit 1
    }
    grep -q 'STRATA_DENSE_FP16' src/prefill/gemm.cu || {
      echo "tiberius.patch did not introduce the STRATA_DENSE_FP16 dense GEMM path" >&2
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
