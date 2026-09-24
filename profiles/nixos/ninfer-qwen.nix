{
  config,
  lib,
  pkgs,
  ...
}:

let
  service = "${config.networking.hostName}-ninfer";
  package = pkgs.ninfer-sm75.override {
    nvidiaPackage = config.hardware.nvidia.package;
  };
  modelRoot = "/persist/ninfer";
  # The newer HF main artifact adds DFlash2 weights and needs a newer runtime.
  # Pin the v1 conversion understood by this Turing fork, not a moving branch.
  revision = "18dfc887423fa5aabf3cb56fac41490e462b3fab";
  modelPath = "${modelRoot}/qwen3_8_27b-${revision}.ninfer";
  modelHash = "eec39564993d6e9c7d5e383382a760f093465c9d163ec9a1bd6b80199514bf3e";
  modelBytes = "18210531328";
  modelUrl = "https://huggingface.co/neroued/Qwen3.8-27B-NInfer/resolve/${revision}/qwen3_8_27b.ninfer";
  prepare = pkgs.writeShellApplication {
    name = "ninfer-qwen-prepare";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
      pkgs.util-linux
    ];
    text = ''
      umask 022
      mkdir -p ${modelRoot}
      cd ${modelRoot}
      exec 9>.prepare.lock
      flock -x 9
      target=${lib.escapeShellArg modelPath}
      partial="$target.partial"
      verify() {
        [ "$(stat -c %s "$1")" = ${modelBytes} ] &&
          printf '%s  %s\n' ${modelHash} "$1" | sha256sum --check --status
      }
      if [ -e "$target" ]; then
        if ! verify "$target"; then
          echo "Existing NInfer model failed verification; refusing to overwrite it." >&2
          exit 1
        fi
        exit 0
      fi
      # Resume interrupted transfers. Never publish an unchecked or partial file.
      if [ -e "$partial" ] && [ "$(stat -c %s "$partial")" -gt ${modelBytes} ]; then
        echo "Oversized NInfer partial; move it aside before retrying." >&2
        exit 1
      fi
      if [ ! -e "$partial" ] || [ "$(stat -c %s "$partial")" -lt ${modelBytes} ]; then
        curl --fail --location --silent --show-error \
          --proto '=https' --proto-redir '=https' \
          --connect-timeout 30 --speed-limit 1024 --speed-time 120 \
          --retry 5 --continue-at - --output "$partial" ${lib.escapeShellArg modelUrl}
      fi
      if ! verify "$partial"; then
        echo "NInfer model checksum mismatch; move the partial aside before retrying." >&2
        exit 1
      fi
      chmod 0444 "$partial"
      mv "$partial" "$target"
    '';
  };
in
{
  environment.systemPackages = [
    package
    prepare
  ];

  systemd.tmpfiles.rules = [ "d ${modelRoot} 0755 root root -" ];
  systemd.services = {
    "${service}-prepare" = {
      description = "Prepare the checksum-pinned Qwen3.8 NInfer artifact";
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      unitConfig.RequiresMountsFor = modelRoot;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = lib.getExe prepare;
        TimeoutStartSec = "2h";
        MemoryHigh = "512M";
        MemoryMax = "768M";
        MemorySwapMax = "256M";
        Nice = 10;
        UMask = "0022";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ modelRoot ];
      };
    };

    "${service}" = {
      description = "Native NInfer Qwen3.8-27B on Turing SM75";
      wantedBy = [ "multi-user.target" ];
      requires = [ "${service}-prepare.service" ];
      after = [
        "${service}-prepare.service"
        "nvidia-persistenced.service"
      ];
      unitConfig = {
        RequiresMountsFor = modelRoot;
        StartLimitIntervalSec = 600;
        StartLimitBurst = 3;
      };
      environment = {
        OMP_NUM_THREADS = "1";
        CUDA_CACHE_PATH = "/var/cache/${service}/cuda";
      };
      serviceConfig = {
        Type = "exec";
        ExecStart = "${package}/bin/ninfer-serve ${
          lib.escapeShellArgs [
            modelPath
            "--model-id"
            "qwen3.8-27b"
            # No firewall port is opened; tailscale0 is trusted by its profile.
            "--host"
            "0.0.0.0"
            "--port"
            "8080"
            "--max-context"
            "131072"
            "--kv-capacity"
            "131072"
            # Corrected INT8 kernels passed near-limit retrieval and cache reuse.
            "--kv-dtype"
            "int8"
            "--max-concurrency"
            "1"
            "--max-pending-requests"
            "2"
            "--pending-timeout-ms"
            "1800000"
            "--prefill-chunk"
            "1024"
            "--max-request-mib"
            "8"
            "--response-store-max-mib"
            "32"
            # Leave speculation disabled: MTP's additional KV/state/graph
            # reservation does not fit this 128K profile on the 22 GiB GPU.
          ]
        }";
        Restart = "on-failure";
        RestartSec = "15s";
        TimeoutStopSec = "30s";
        LimitMEMLOCK = "infinity";
        MemoryHigh = "4G";
        MemoryMax = "5G";
        MemorySwapMax = "1G";
        DynamicUser = true;
        CacheDirectory = service;
        UMask = "0077";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
      };
    };
  };
}
