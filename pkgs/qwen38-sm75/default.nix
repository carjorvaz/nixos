{
  lib,
  runCommand,
  writeShellScriptBin,
  symlinkJoin,
  fetchFromGitHub,
  python312,
  patch,
  coreutils,
  bash,
  ninja,
  cudaPackages,
  linuxPackages,
  nvidiaPackage ? linuxPackages.nvidiaPackages.stable,
  zlib,
  glibc,
  cacert,
}:

let
  upstream = fetchFromGitHub {
    owner = "syv-ai";
    repo = "qwen38-27b-rtx3090";
    rev = "18349177b7962ef1d699dc154844f9c04317a474";
    hash = "sha256-KAB81VzNkPr4Hy2Vqbt09MAn7crBkVDAk4tvatRte7w=";
  };
  # Content-address this directory so unrelated repo commits do not change the
  # asset store path (which would restart the service on every switch).
  local = builtins.path {
    path = ./.;
    name = "qwen38-sm75-local";
  };
  assets = runCommand "qwen38-sm75-assets" { } ''
    mkdir -p "$out"
    cp ${local}/prepare-runtime.py "$out/prepare-runtime.py"
    cp ${local}/prepare-model.py "$out/prepare-model.py"
    cp ${local}/requirements.lock "$out/requirements.lock"
    cp ${local}/check-attention.py "$out/check-attention.py"
    cp ${local}/check-downloads.py "$out/check-downloads.py"
    cp ${local}/check-prefill.py "$out/check-prefill.py"
    cp ${local}/check-prefix.py "$out/check-prefix.py"
    cp ${local}/check-gdn.py "$out/check-gdn.py"
    cp ${local}/bench-one.py "$out/bench-one.py"
    cp ${local}/prepare-uncensored.py "$out/prepare-uncensored.py"
    cp ${local}/soak.py "$out/soak.py"
    cp ${local}/copy-bench.py "$out/copy-bench.py"
    cp ${local}/sample-probe.py "$out/sample-probe.py"
    cp -r ${local}/patches "$out/patches"
  '';
  python = "${python312}/bin/python3.12";
  compiler = cudaPackages.backendStdenv.cc;
  # JIT users expect one CUDA_HOME with both nvcc and runtime/CCCL headers.
  cudaHome = symlinkJoin {
    name = "qwen38-sm75-cuda-development";
    paths = lib.unique [
      cudaPackages.cuda_nvcc
      (lib.getBin cudaPackages.cuda_nvcc)
      (lib.getDev cudaPackages.cuda_nvcc)
      (lib.getDev cudaPackages.cuda_cudart)
      (lib.getLib cudaPackages.cuda_cudart)
      (lib.getDev cudaPackages.cuda_cccl)
      (lib.getDev cudaPackages.libcurand)
      (lib.getOutput "include" cudaPackages.libcurand)
      (lib.getLib cudaPackages.libcurand)
    ];
    postBuild = ''
      ln -s lib "$out/lib64"
      ln -s ${lib.getLib nvidiaPackage}/lib/libcuda.so "$out/lib/libcuda.so"
    '';
  };
  environment = ''
    # Wheel-bundled ninja/nvcc executables use non-Nix ELF interpreters.
    export PATH="${
      lib.makeBinPath [
        coreutils
        # Ninja resolves sh through PATH, independently of wrapper shebangs.
        bash
        compiler
        patch
        ninja
        cudaPackages.cuda_nvcc
      ]
    }:$root/venv/bin"
    export CC=${compiler}/bin/cc
    export CXX=${compiler}/bin/c++
    export CUDAHOSTCXX="$CXX"
    export NVCC_CCBIN="$CXX"
    export LD_LIBRARY_PATH=${
      lib.makeLibraryPath [
        nvidiaPackage
        compiler.cc.lib
        cudaPackages.cuda_cudart
        zlib
        glibc
      ]
    }
    # Triton otherwise probes /sbin/ldconfig, which does not exist on NixOS.
    export TRITON_LIBCUDA_PATH=${lib.getLib nvidiaPackage}/lib
    export TRITON_PTXAS_PATH=${lib.getBin cudaPackages.cuda_nvcc}/bin/ptxas
    export CUDA_HOME=${cudaHome}
    export MAX_JOBS=1
    export SSL_CERT_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt
    export REQUESTS_CA_BUNDLE="$SSL_CERT_FILE"
    export PIP_CERT="$SSL_CERT_FILE"
    export PYTHONNOUSERSITE=1
    unset PYTHONPATH PYTHONHOME
    export XDG_CACHE_HOME="$root/cache"
    export HF_HOME="$root/cache/huggingface"
    export PIP_CACHE_DIR="$root/cache/pip"
    export TRITON_CACHE_DIR="$root/cache/triton"
    export TORCH_EXTENSIONS_DIR="$root/cache/torch-extensions"
    export TORCHINDUCTOR_CACHE_DIR="$root/cache/torchinductor"
    export FLASHINFER_WORKSPACE_BASE="$root/cache/flashinfer"
    export VLLM_CACHE_ROOT="$root/cache/vllm"
    export VLLM_NO_USAGE_STATS=1
    export DO_NOT_TRACK=1
    export HF_HUB_DISABLE_TELEMETRY=1
    export ANONYMIZED_TELEMETRY=False
    export OTEL_SDK_DISABLED=true
  '';
  prepare = writeShellScriptBin "qwen38-sm75-prepare" ''
    set -euo pipefail
    if [ "$#" -gt 1 ]; then
      echo "Usage: qwen38-sm75-prepare [ROOT]" >&2
      exit 2
    fi
    root="''${1:-/persist/qwen38-sm75}"
    ${coreutils}/bin/mkdir -p "$root"
    root="$(${coreutils}/bin/realpath "$root")"
    ${environment}
    ${python} ${assets}/prepare-runtime.py "$root" ${upstream} ${assets} ${python}
    exec "$root/venv/bin/python" ${assets}/prepare-model.py "$root"
  '';
  serve = writeShellScriptBin "qwen38-sm75-serve" ''
    set -euo pipefail
    root="''${QWEN_RUNTIME_ROOT:-/persist/qwen38-sm75}"
    root="$(${coreutils}/bin/realpath -e "$root")"
    ${environment}
    exec ${python} ${assets}/prepare-runtime.py "$root" ${upstream} ${assets} ${python} --serve "$@"
  '';
  check = writeShellScriptBin "qwen38-sm75-check" ''
    set -euo pipefail
    case "''${1:-}" in
      attention|prefill|prefix|gdn|downloads) check="$1" ;;
      *) echo "Usage: qwen38-sm75-check attention|prefill|prefix|gdn|downloads" >&2; exit 2 ;;
    esac
    root="''${QWEN_RUNTIME_ROOT:-/persist/qwen38-sm75}"
    root="$(${coreutils}/bin/realpath -e "$root")"
    ${environment}
    exec "$root/venv/bin/python" "${assets}/check-$check.py"
  '';
  bench = writeShellScriptBin "qwen38-sm75-bench" ''
    set -euo pipefail
    root="''${QWEN_RUNTIME_ROOT:-/persist/qwen38-sm75}"
    root="$(${coreutils}/bin/realpath -e "$root")"
    ${environment}
    exec "$root/venv/bin/python" "${assets}/bench-one.py" "$@"
  '';
  soak = writeShellScriptBin "qwen38-sm75-soak" ''
    set -euo pipefail
    root="''${QWEN_RUNTIME_ROOT:-/persist/qwen38-sm75}"
    root="$(${coreutils}/bin/realpath -e "$root")"
    ${environment}
    exec "$root/venv/bin/python" "${assets}/soak.py" "$@"
  '';
  copyBench = writeShellScriptBin "qwen38-sm75-copy-bench" ''
    set -euo pipefail
    root="''${QWEN_RUNTIME_ROOT:-/persist/qwen38-sm75}"
    root="$(${coreutils}/bin/realpath -e "$root")"
    ${environment}
    exec "$root/venv/bin/python" "${assets}/copy-bench.py" "$@"
  '';
  sampleProbe = writeShellScriptBin "qwen38-sm75-sample-probe" ''
    set -euo pipefail
    root="''${QWEN_RUNTIME_ROOT:-/persist/qwen38-sm75}"
    root="$(${coreutils}/bin/realpath -e "$root")"
    ${environment}
    exec "$root/venv/bin/python" "${assets}/sample-probe.py" "$@"
  '';
  prepareUncensored = writeShellScriptBin "qwen38-sm75-prepare-uncensored" ''
    set -euo pipefail
    if [ "$#" -gt 1 ]; then
      echo "Usage: qwen38-sm75-prepare-uncensored [MODEL_ROOT]" >&2
      exit 2
    fi
    # The runtime (venv, caches) is separate from the model root so the
    # uncensored checkpoint can live on another pool.
    root="''${QWEN_RUNTIME_ROOT:-/persist/qwen38-sm75}"
    root="$(${coreutils}/bin/realpath -e "$root")"
    ${environment}
    target="''${1:-$root}"
    ${coreutils}/bin/mkdir -p "$target"
    target="$(${coreutils}/bin/realpath "$target")"
    exec "$root/venv/bin/python" "${assets}/prepare-uncensored.py" "$target"
  '';
in
assert lib.versions.majorMinor cudaPackages.cuda_nvcc.version == "12.9";
symlinkJoin {
  name = "qwen38-sm75-0.28.0";
  paths = [
    prepare
    serve
    check
    bench
    soak
    copyBench
    sampleProbe
    prepareUncensored
  ];
  meta = {
    description = "Pinned Qwen3.8-27B vLLM runtime preparation and serving for Turing GPUs";
    homepage = "https://github.com/syv-ai/qwen38-27b-rtx3090";
    mainProgram = "qwen38-sm75-serve";
    platforms = [ "x86_64-linux" ];
  };
}
