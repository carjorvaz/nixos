{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  autoAddDriverRunpath,
  linuxPackages,
  nvidiaPackage ? linuxPackages.nvidiaPackages.stable,
  glibc,
  openssl,
  cudaPackages,
  zlib,
}:

# Mainline llama.cpp CUDA release, the upstream sibling of beellama-cuda.nix.
# The official Linux CUDA 12.8 archive carries sm75 device code, so Turing runs
# it without a source build. Upstream tags are the pin: the tarball is a
# prebuilt binary, not a reproducible source build.
stdenv.mkDerivation {
  pname = "llama-cpp-cuda";
  version = "b11050";

  src = fetchurl {
    url = "https://github.com/ggml-org/llama.cpp/releases/download/b11050/llama-b11050-bin-ubuntu-cuda-12.8-x64.tar.gz";
    hash = "sha256-goXS3l4s5v02lfVQYCLMiX/KsKCfZJOh9os4TWJNDZM=";
  };

  nativeBuildInputs = [
    autoPatchelfHook
    autoAddDriverRunpath
  ];
  buildInputs = [
    # Headless hosts may lack /run/opengl-driver. Let the caller select the
    # same driver package as its kernel module for direct libcuda resolution.
    nvidiaPackage
    glibc
    openssl
    stdenv.cc.cc.lib
    cudaPackages.cuda_cudart
    cudaPackages.libcublas
    zlib
  ];

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin $out/lib
    cp -a ./*.so* $out/lib/
    find . -maxdepth 1 -type f -executable -not -name "*.so*" -exec cp -a {} $out/bin/ \;
    # ggml finds and dlopens its backends by scanning the directory of the
    # running executable, and the llama-*-impl.so launchers are loaded from the
    # same place. Symlinks satisfy both that scan and autoPatchelf's rpath.
    for so in $out/lib/*.so*; do
      ln -s "$so" "$out/bin/$(basename "$so")"
    done
    runHook postInstall
  '';

  meta = {
    description = "Mainline llama.cpp with CUDA (prebuilt release, sm75-capable)";
    homepage = "https://github.com/ggml-org/llama.cpp";
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    mainProgram = "llama-server";
    platforms = [ "x86_64-linux" ];
  };
}
