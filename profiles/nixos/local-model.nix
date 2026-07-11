{
  lib,
  pkgs,
  ...
}:

let
  modelId = "trajanus-ornith/ornith-1.0-35b-heretic-q4km-262k";
  modelPath = "/models/gguf/ornith-1.0-35b/llmfan46/Ornith-1.0-35B-uncensored-heretic-Q4_K_M.gguf";
  llamaBin = "/models/sota-src/llama.cpp-mainline-latest/build-vulkan/bin/llama-server";
  llamaLibDir = "/models/sota-src/llama.cpp-mainline-latest/build-vulkan/bin";
  localModelDomain = "llm.trajanus.vaz.ovh";
  localModelPort = 18083;

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
  # services.llama-cpp comes from nixpkgs.
  # Unlike pius's ik_llama (CPU-only, Nix-packaged), this wraps a pre-built
  # Vulkan binary from /models/sota-src for the Radeon 780M iGPU.
  #
  # To swap models later: change modelPath and rebuild. The binary path may
  # also change if the llama.cpp source tree is updated.
  services = {
    nginx = {
      tailscaleAuth = {
        enable = true;
        virtualHosts = [ localModelDomain ];
      };

      virtualHosts.${localModelDomain} = {
        forceSSL = true;
        useACMEHost = "vaz.ovh";
        locations."/" = {
          proxyPass = "http://127.0.0.1:${toString localModelPort}";
          proxyWebsockets = true;
          extraConfig = ''
            proxy_read_timeout 3600s;
            proxy_send_timeout 3600s;
            proxy_buffering off;
            proxy_request_buffering off;
          '';
        };
      };
    };

    llama-cpp = {
      enable = true;
      package = wrapped-llama-server;
      openFirewall = false;
      settings = {
        host = "127.0.0.1";
        port = localModelPort;
        model = modelPath;
        alias = modelId;
        no-webui = true;
        n-gpu-layers = 99;
        flash-attn = "on";
        ctx-size = 262144;
        parallel = 1;
        threads = 4;
        threads-batch = 4;
        batch-size = 1024;
        ubatch-size = 512;
        cache-type-k = "q4_0";
        cache-type-v = "q4_0";
        no-host = true;
        poll = 0;
        timeout = 3600;
        reasoning = "off";
        reasoning-budget = 0;
        # Keep prompt-cache features enabled without taking llama.cpp's 8 GiB default.
        cache-ram = 512;
        ctx-checkpoints = 32;
        log-colors = "off";
      };
    };
  };

  systemd.services.llama-cpp = {
    # The model lives on a ZFS dataset (zdata/models) that may mount late.
    unitConfig.RequiresMountsFor = "/models";
    serviceConfig = {
      # GPU access — the 780M is exposed via /dev/dri/renderD128.
      SupplementaryGroups = [
        "video"
        "render"
      ];
      Environment = lib.mkAfter [
        "HOME=/var/cache/llama-cpp"
        "XDG_CACHE_HOME=/var/cache/llama-cpp"
      ];
      # Vulkan needs real /dev/dri access, not PrivateDevices.
      PrivateDevices = lib.mkForce false;
      PrivateUsers = lib.mkForce false;
    };
  };
}
