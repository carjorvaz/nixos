{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  autoAddDriverRunpath,
  unzip,
  linuxPackages,
  nvidiaPackage ? linuxPackages.nvidiaPackages.stable,
  glibc,
  openssl,
  cudaPackages,
  zlib,
}:

let
  # The CUDA backend links NCCL even for single-GPU inference. Use NVIDIA's
  # pinned binary wheel rather than compiling nixpkgs' NCCL from source.
  nccl = fetchurl {
    url = "https://files.pythonhosted.org/packages/4a/4e/44dbb46b3d1b0ec61afda8e84837870f2f9ace33c564317d59b70bc19d3e/nvidia_nccl_cu12-2.28.9-py3-none-manylinux_2_18_x86_64.whl";
    hash = "sha256-SFd22qhEfaXaOWga9FWqOywlht3PSvh3JJXnxTLH5as=";
  };
in
# The official CUDA 12.4 release supports Turing and avoids the fork's
# memory-intensive CUDA compilation. Patch its ELF interpreter and runpaths.
stdenv.mkDerivation {
  pname = "beellama-cuda";
  version = "0.4.6";

  src = fetchurl {
    url = "https://github.com/Anbeeld/beellama.cpp/releases/download/v0.4.6/beellama-v0.4.6-bin-ubuntu-cuda-12.4-x64.tar.gz";
    hash = "sha256-h5c1cZm1PtkJb6aVM/wi7D14uhnrJFe/y1Uki+zGJs0=";
  };

  nativeBuildInputs = [
    autoPatchelfHook
    autoAddDriverRunpath
    unzip
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
    cp -a llama-server $out/bin/
    unzip -j ${nccl} 'nvidia/nccl/lib/libnccl.so.2*' -d $out/lib
    # ggml finds and dlopens its backends by scanning the directory of the
    # running executable, while autoPatchelfHook wires interpreters and rpaths
    # around $out/lib. Symlinks satisfy both without merging the two.
    for so in $out/lib/libggml*.so; do
      ln -s "$so" $out/bin/
    done
    runHook postInstall
  '';

  meta = {
    description = "llama.cpp fork with KVarN KV-cache quantization and owned-MTP speculation (prebuilt CUDA release)";
    homepage = "https://github.com/Anbeeld/beellama.cpp";
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    mainProgram = "llama-server";
    platforms = [ "x86_64-linux" ];
  };
}
