{
  lib,
  cudaPackages,
  fetchFromGitHub,
  cmake,
  ninja,
  pkg-config,
  ffmpeg,
  curl,
  makeWrapper,
  symlinkJoin,
  writeText,
  linuxPackages,
  nvidiaPackage ? linuxPackages.nvidiaPackages.stable,
}:

let
  src = fetchFromGitHub {
    owner = "mr-september";
    repo = "ninfer-2080ti-22g";
    rev = "6460bf03a86f1288dc7b240d70c30887199099af";
    hash = "sha256-ytXltscJa0VEqduR0M6q9b+6VVz3c026HUDLQKRFZ5w=";
  };
  # Content-address this directory: without it, every commit in the repo
  # changes the flake source tree and rebuilds this heavy CUDA package.
  local = builtins.path {
    path = ./.;
    name = "ninfer-sm75-local";
  };
  patches = [
    "${local}/patches/turing-int8-correctness.patch"
    "${local}/patches/turing-initialized-mma-padding.patch"
    "${local}/patches/turing-fp8-a16-fallback.patch"
    "${local}/patches/turing-w8-vocab-simt.patch"
    "${local}/patches/turing-q5-residual-slices.patch"
  ];
  # This upstream header has CRLF; keep our reviewed patches ordinary LF text.
  prePatch = ''
    substituteInPlace src/ops/common/mma.cuh --replace-fail $'\r' ""
  '';
  cudaInputs = with cudaPackages; [
    cuda_cudart
    cuda_cccl
    cuda_nvtx
  ];
  driverPath = "${lib.getLib nvidiaPackage}/lib";
  testSources = {
    gqa_attention = "ops/test_gqa_attention.cpp";
    linear_q4_a16 = "ops/linear/test_q4_a16.cpp";
    linear_q5_a16 = "ops/linear/test_q5_a16.cpp";
    linear_q6_a16 = "ops/linear/test_q6_a16.cpp";
    linear_w8_a16 = "ops/linear/test_w8_a16.cpp";
    linear_bf16_a16 = "ops/linear/test_bf16_a16.cpp";
    linear_fp8_a16 = "ops/linear/test_fp8_a16.cpp";
    linear_fp8_a8 = "ops/linear/test_fp8_a8.cpp";
    linear_add_fp8 = "ops/linear_add/test_fp8.cpp";
    linear_add_q5_a16 = "ops/linear_add/test_q5_a16.cpp";
    linear_swiglu_fp8 = "ops/linear_swiglu/test_fp8.cpp";
    gated_delta_net = "ops/test_gated_delta_net.cpp";
    attn_input_proj = "ops/test_attn_input_proj.cpp";
    gdn_input_proj = "ops/test_gdn_input_proj.cpp";
    gdn_replay_fold = "ops/test_gdn_replay_fold.cpp";
    gdn_input_proj_conv_snapshot = "ops/test_gdn_input_proj_conv_snapshot.cpp";
    gdn_input_proj_conv_record = "ops/test_gdn_input_proj_conv_record.cpp";
    gated_delta_net_replay_record = "ops/test_gated_delta_net_replay_record.cpp";
  };
  testNames = builtins.attrNames testSources;

  # Small, independently buildable device regressions, before a full CUDA build.
  # Deliberately NOT passthru.tests or doCheck: execution requires a real SM75 GPU.
  makeDeviceCheck =
    name: source:
    cudaPackages.backendStdenv.mkDerivation {
      pname = "ninfer-sm75-check-${name}";
      version = "1";
      inherit src patches prePatch;
      nativeBuildInputs = [
        cudaPackages.cuda_nvcc
        makeWrapper
      ];
      buildInputs = cudaInputs;
      dontConfigure = true;
      doCheck = false;
      buildPhase = ''
        runHook preBuild
        nvcc -ccbin "$CXX" -std=c++20 -O2 -arch=sm_75 --cudart=shared \
          -DNINFER_SM75=1 -I src -I include \
          ${source} -o ninfer-sm75-check-${name}
        runHook postBuild
      '';
      installPhase = ''
        install -Dm755 ninfer-sm75-check-${name} "$out/bin/ninfer-sm75-check-${name}"
      '';
      postFixup = ''
        patchelf --add-rpath ${driverPath} "$out/bin/ninfer-sm75-check-${name}"
        wrapProgram "$out/bin/ninfer-sm75-check-${name}" --prefix LD_LIBRARY_PATH : ${driverPath}
      '';
      meta = {
        description = "Opt-in SM75 ${name} GPU regression";
        license = lib.licenses.asl20;
        mainProgram = "ninfer-sm75-check-${name}";
        platforms = [ "x86_64-linux" ];
      };
    };
  mmaCheck = makeDeviceCheck "mma" "${local}/check-mma.cu";
  paddingCheck = makeDeviceCheck "padding" "${local}/check-padding.cu";

  # Use CUDA's supported host compiler rather than the default stdenv compiler.
  unwrapped = cudaPackages.backendStdenv.mkDerivation {
    pname = "ninfer-sm75";
    version = "0-unstable-2026-08-22";
    inherit src patches prePatch;
    outputs = [
      "out"
      "dev"
    ];
    nativeBuildInputs = [
      cmake
      ninja
      pkg-config
      cudaPackages.cuda_nvcc
    ];
    buildInputs = cudaInputs ++ [
      ffmpeg
      curl
    ];
    cmakeFlags = [
      (lib.cmakeFeature "CMAKE_CUDA_ARCHITECTURES" "75")
      (lib.cmakeBool "NINFER_BUILD_APPS" true)
      (lib.cmakeBool "BUILD_TESTING" false)
      (lib.cmakeBool "NINFER_BUILD_BENCHMARKS" false)
    ];
    ninjaFlags = [
      "ninfer"
      "ninfer-serve"
    ];
    doCheck = false;

    # Upstream has no install target. Export internal archives separately so test
    # changes do not trigger another expensive CUDA build or enter the service closure.
    installPhase = ''
      runHook preInstall
      install -Dm755 apps/ninfer "$out/bin/ninfer"
      install -Dm755 apps/ninfer-serve "$out/bin/ninfer-serve"
      install -Dm644 src/libninfer_ops.a "$dev/lib/libninfer_ops.a"
      install -Dm644 src/libninfer_core.a "$dev/lib/libninfer_core.a"
      runHook postInstall
    '';

    # Headless NixOS need not have /run/opengl-driver. cudart's dlopen also needs
    # the matching driver in LD_LIBRARY_PATH, not just executable DT_RUNPATH.
    postFixup = ''
      for program in "$out"/bin/*; do
        patchelf --add-rpath ${driverPath} "$program"
      done
    '';
    doInstallCheck = true;
    installCheckPhase = ''
      runHook preInstallCheck
      "$out/bin/ninfer" --help > /dev/null
      "$out/bin/ninfer-serve" --help > /dev/null
      runHook postInstallCheck
    '';
    meta = {
      description = "Native Qwen inference CLI and OpenAI/Anthropic server for Turing SM75 GPUs";
      homepage = "https://github.com/mr-september/ninfer-2080ti-22g";
      license = lib.licenses.asl20;
      mainProgram = "ninfer-serve";
      platforms = [ "x86_64-linux" ];
      outputsToInstall = [ "out" ];
    };
  };

  # Keep upstream test mains and numerical oracles intact. One dispatcher avoids
  # copying the same large CUDA archive into every test executable; wrappers
  # retain their original names and each invocation still gets its own process.
  gpuTestMain = writeText "ninfer-sm75-gpu-tests.cpp" ''
    #include <exception>
    #include <iostream>
    #include <string_view>
    ${lib.concatMapStringsSep "\n" (name: "int ninfer_${name}_test_main();") testNames}
    int main(int argc, char** argv) {
      if (argc != 2) { std::cerr << "Expected one operation test name\n"; return 2; }
      const std::string_view name(argv[1]);
      try {
        ${lib.concatMapStringsSep "\n" (name: ''
          if (name == "${name}") return ninfer_${name}_test_main();
        '') testNames}
      } catch (const std::exception& error) {
        std::cerr << name << ": " << error.what() << '\n'; return 1;
      }
      std::cerr << "Unknown operation test: " << name << '\n'; return 2;
    }
  '';
  gpuTests = cudaPackages.backendStdenv.mkDerivation {
    pname = "ninfer-sm75-gpu-tests";
    inherit (unwrapped) version;
    inherit src prePatch;
    patches = patches ++ [
      "${local}/patches/turing-attention-regressions.patch"
      "${local}/patches/test-projection-architecture.patch"
      "${local}/patches/test-fp8-capabilities.patch"
    ];
    nativeBuildInputs = [ makeWrapper ];
    # Host-only C++ tests still need the toolkit's separately packaged crt headers.
    buildInputs = cudaInputs ++ [ cudaPackages.cuda_nvcc ];
    dontConfigure = true;
    doCheck = false;
    buildPhase = ''
      runHook preBuild
      flags=(-std=c++20 -O3 -DNDEBUG -DNINFER_SM75=1 -fno-fast-math -ffp-contract=off
             -I src -I include -I tests -I third_party -I third_party/utf8proc)
      ${lib.concatStringsSep "\n" (
        lib.mapAttrsToList (name: file: ''
          $CXX "''${flags[@]}" -Dmain=ninfer_${name}_test_main -c tests/${file} -o ${name}.o
        '') testSources
      )}
      $CXX "''${flags[@]}" -c tests/ops/linear/linear_test_common.cpp -o linear_common.o
      $CXX "''${flags[@]}" -c tests/ops/linear_swiglu/linear_swiglu_test_common.cpp -o swiglu_common.o
      $CXX "''${flags[@]}" -c tests/ops/linear_add/linear_add_test_common.cpp -o linear_add_common.o
      $CXX "''${flags[@]}" ${gpuTestMain} ./*.o \
        ${unwrapped.dev}/lib/libninfer_ops.a ${unwrapped.dev}/lib/libninfer_core.a \
        -lcudart -ldl -pthread -lrt -o ninfer-sm75-gpu-tests
      runHook postBuild
    '';
    installPhase = ''
      install -Dm755 ninfer-sm75-gpu-tests "$out/libexec/ninfer-sm75-gpu-tests"
      for name in ${lib.concatStringsSep " " testNames}; do
        makeWrapper "$out/libexec/ninfer-sm75-gpu-tests" "$out/bin/ninfer_''${name}_test" \
          --add-flags "$name" --prefix LD_LIBRARY_PATH : ${driverPath}
      done
    '';
    postFixup = ''
      patchelf --add-rpath ${driverPath} "$out/libexec/ninfer-sm75-gpu-tests"
    '';
    meta = {
      description = "Opt-in operation regressions linked to NInfer's production CUDA libraries";
      license = lib.licenses.asl20;
      platforms = [ "x86_64-linux" ];
    };
  };
in
symlinkJoin {
  inherit (unwrapped) name meta;
  paths = [ unwrapped ];
  nativeBuildInputs = [ makeWrapper ];
  postBuild = ''
    for program in "$out/bin/ninfer" "$out/bin/ninfer-serve"; do
      wrapProgram "$program" --prefix LD_LIBRARY_PATH : ${driverPath}
    done
  '';
  passthru = {
    inherit
      unwrapped
      mmaCheck
      paddingCheck
      gpuTests
      ;
  };
}
