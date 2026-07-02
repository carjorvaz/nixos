{
  _self,
  _config,
  lib,
  pkgs,
  ...
}:

let
  modelPath = "/models/gguf/ornith-1.0-35b/ilintar/Ornith-1.0-35B-4.25bpw.gguf";
  llamaBin = "/models/sota-src/llama.cpp-mainline-latest/build-vulkan/bin/llama-server";
  llamaLibDir = "/models/sota-src/llama.cpp-mainline-latest/build-vulkan/bin";
  localModelPort = 8080;

  # Wrap the pre-built Vulkan binary as a Nix derivation.
  # The binary uses shared .so files from the same directory.
  wrapped-llama-server = pkgs.runCommand "llama-server-vulkan" { } ''
    mkdir -p $out/bin
    cat > $out/bin/llama-server << 'WRAPPER'
    #!${pkgs.bash}/bin/bash
    export LD_LIBRARY_PATH="${llamaLibDir}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    exec ${llamaBin} "$@"
    WRAPPER
    chmod +x $out/bin/llama-server
  '';
in
{
  # services.llama-cpp comes from nixpkgs (via llm-agents.nix overlay).
  # Unlike pius's ik_llama (CPU-only, Nix-packaged), this wraps a pre-built
  # Vulkan binary from /models/sota-src for the Radeon 780M iGPU.
  #
  # To swap models later: change modelPath and rebuild. The binary path may
  # also change if the llama.cpp source tree is updated.
  services.llama-cpp = {
    enable = true;
    package = wrapped-llama-server;
    openFirewall = true;
    settings = {
      host = "0.0.0.0";
      port = localModelPort;
      model = modelPath;
      n-gpu-layers = 99;
      flash-attn = "on";
      ctx-size = 65536;
      parallel = 1;
    };
  };

  systemd.services.llama-cpp.serviceConfig = {
    # GPU access — the 780M is exposed via /dev/dri/renderD128
    SupplementaryGroups = [
      "video"
      "render"
    ];
    # The model lives on a ZFS dataset (zdata/models) that may mount late
    RequiresMountsFor = [ "/models" ];
    # Vulkan needs real /dev/dri access, not PrivateDevices
    PrivateDevices = lib.mkForce false;
  };
}
