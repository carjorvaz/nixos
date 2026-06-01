{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:

# STATE:
# - Current pius daily driver is HauhauCS Qwen3.6 35B-A3B Aggressive Q4_K_M.
# - The model was archived and SHA256-verified against HF commit f12a584 on
#   2026-05-06. See /persist/models/RETENTION.md and RUNTIME-NOTES.md on pius.

let
  cfg = config.services.ik-llama;
  model = "qwen3.6-35b-a3b-hauhau-aggressive";
  model27b = "qwen3.6-27b-hauhau-balanced";
  model27bFast = "qwen3.6-27b-hauhau-balanced-fast";
  llamaPort = 8012;
  modelPath = "/persist/models/qwen3.6-35b-a3b-hauhaucs-aggressive/HauhauCS/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive-Q4_K_M.gguf";
  model27bPath = "/persist/models/qwen3.6-27b-hauhaucs-balanced/HauhauCS/Qwen3.6-27B-Uncensored-HauhauCS-Balanced-Q4_K_P.gguf";
  fastCpus = "0-5";
  fastThreads = 6;

  # ik_llama.cpp: upstream bug — package.nix returns env = [] (a list) instead
  # of {} when useRocm is false. mkDerivation requires env to be an attrset.
  patchedStdenv = pkgs.stdenv // {
    mkDerivation =
      fnOrAttrs:
      pkgs.stdenv.mkDerivation (
        if builtins.isFunction fnOrAttrs then
          finalAttrs:
          let
            result = fnOrAttrs finalAttrs;
          in
          result // { env = if builtins.isList (result.env or { }) then { } else result.env; }
        else
          fnOrAttrs // { env = if builtins.isList (fnOrAttrs.env or { }) then { } else fnOrAttrs.env; }
      );
  };

  ik-llama =
    (pkgs.callPackage "${inputs.ik-llama}/.devops/nix/package.nix" {
      effectiveStdenv = patchedStdenv;
    }).overrideAttrs
      (old: {
        cmakeFlags = old.cmakeFlags ++ [
          (lib.cmakeBool "GGML_LTO" true)
        ];
      });

  commonFlags =
    {
      alias,
      threads ? cfg.threads,
    }:
    [
      "-t"
      (toString threads)
      "--threads-batch"
      (toString threads)

      # Context: 1 slot x 128K with Q8 KV
      "-c"
      "131072"
      "--cache-type-k"
      "q8_0"
      "--cache-type-v"
      "q8_0"

      # Batch sizes
      "-b"
      "2048"
      "-ub"
      "512"

      # Avoid the extra host prompt cache. On pius Qwen3.6 35B A3B this was
      # neutral/slightly faster and saves up to the default 8 GiB under
      # memory pressure; normal per-slot KV context is unaffected.
      "-cram"
      "0"

      # Lock model in RAM (prevents swapping under memory pressure)
      "--mlock"

      # Jinja templates: use the Hauhau/Qwen3.6 GGUF-embedded template.
      "--jinja"

      # ik_llama.cpp: flash attention. Q8 KV requires flash attention in current
      # Qwen3.6 tests; disabling it fails context creation.
      "-fa"
      "auto"

      # ik_llama.cpp: repack tensors into interleaved format at load time.
      # One-time cost at startup, faster inference thereafter.
      # 2026-05-05/06 pius Qwen3.6 35B A3B tests: 4/5/6 threads were
      # close in clean server runs, with 6 usually a few percent ahead.
      # 2026-05-08 pius Qwen3.6 27B dense tests: 4 threads beat 5/6 inside
      # the workload slice. Native MTP GGUFs load with current ik_llama.cpp, but
      # draft depths 1/2/4 did not improve decode speed on CPU-only pius.
      # Keep 4 as the home-server default to leave cores available. -muge/-mqkv,
      # ngram speculation, MTP on non-MTP GGUFs, checkpoint disabling, expert
      # reduction, affinity pinning, performance governor, and a skylake-targeted
      # build did not improve the real short-chat path.
      "--run-time-repack"

      # Qwen3.6 non-thinking general defaults (overridable per request by clients).
      "--temp"
      "0.7"
      "--top-p"
      "0.80"
      "--top-k"
      "20"
      "--min-p"
      "0.0"
      "--repeat-penalty"
      "1.0"

      # Single slot: ik_llama.cpp's "-fa auto" (optimized flash attention) crashes
      # with GGML_ASSERT(S > 0) in iqk_fa_templates.h when --parallel > 1.
      "--parallel"
      "1"

      # Clean model name for /v1/models and client requests
      "--alias"
      alias
    ];

  switchModel =
    {
      name,
      service,
      alias,
    }:
    pkgs.writeShellScriptBin name ''
      set -euo pipefail

      ${pkgs.systemd}/bin/systemctl start ${lib.escapeShellArg service}

      for _ in $(${pkgs.coreutils}/bin/seq 1 180); do
        if ${pkgs.curl}/bin/curl -fsS --max-time 2 http://127.0.0.1:${toString llamaPort}/v1/models 2>/dev/null \
          | ${pkgs.gnugrep}/bin/grep -q ${lib.escapeShellArg alias}; then
          printf '%s\n' ${lib.escapeShellArg "${alias} ready on :${toString llamaPort}"}
          exit 0
        fi
        ${pkgs.coreutils}/bin/sleep 2
      done

      ${pkgs.systemd}/bin/systemctl --no-pager --full status ${lib.escapeShellArg service}
      exit 1
    '';

  use35b = switchModel {
    name = "llm-use-35b";
    service = "llama-cpp.service";
    alias = model;
  };

  use27b = switchModel {
    name = "llm-use-27b";
    service = "llama-cpp-27b.service";
    alias = model27b;
  };

  use27bFast = switchModel {
    name = "llm-use-27b-fast";
    service = "llama-cpp-27b-fast.service";
    alias = model27bFast;
  };

  companionService =
    {
      description,
      alias,
      conflicts,
      threads ? cfg.threads,
      allowedCpus ? config.cjv.llmTuning.workloadCpus,
      slice ? "llm-workload.slice",
    }:
    {
      inherit description;
      after = [ "network.target" ];
      inherit conflicts;
      path = [
        pkgs.coreutils
        pkgs.findutils
        pkgs.gnugrep
        pkgs.gnused
        pkgs.systemd
      ];
      serviceConfig = {
        Type = "idle";
        DynamicUser = true;
        User = "llama-cpp";
        Group = "llama-cpp";
        ExecStart = "${ik-llama}/bin/llama-server --log-disable --host 127.0.0.1 --port ${toString llamaPort} -m ${model27bPath} ${
          lib.escapeShellArgs (commonFlags {
            inherit alias threads;
          })
        }";
        KillSignal = "SIGINT";
        Restart = "on-failure";
        RestartSec = "10s";
        LimitMEMLOCK = "infinity";
        Slice = slice;
        AllowedCPUs = allowedCpus;
        CPUAccounting = true;
        IOAccounting = true;
        MemoryAccounting = true;
        CapabilityBoundingSet = "";
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        NoNewPrivileges = true;
        PrivateDevices = false;
        PrivateMounts = true;
        PrivateTmp = true;
        PrivateUsers = true;
        ProcSubset = "pid";
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHome = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectProc = "invisible";
        ProtectSystem = "strict";
        RemoveIPC = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
        SystemCallErrorNumber = "EPERM";
        SystemCallFilter = [
          "@system-service"
          "~@privileged"
        ];
      };
    };
in
{
  options.services.ik-llama = {
    threads = lib.mkOption {
      type = lib.types.int;
      default = 4;
      description = "Number of threads for inference; benchmark per host/model, since physical core count can oversaturate memory bandwidth.";
    };
  };

  config = {
    services = {
      # Native llama-server OpenAI-compatible API.
      nginx.virtualHosts."llm.vaz.ovh" = {
        forceSSL = true;
        useACMEHost = "vaz.ovh";
        locations."/" = {
          proxyPass = "http://127.0.0.1:${toString llamaPort}";
          proxyWebsockets = true;
          extraConfig = ''
            proxy_read_timeout 600s;
            proxy_send_timeout 600s;
          '';
        };
      };

      llama-cpp = {
        enable = true;
        package = ik-llama;
        model = modelPath;
        host = "127.0.0.1";
        port = llamaPort;
        extraFlags = commonFlags { alias = model; };
      };
    };

    environment.systemPackages = [
      use35b
      use27b
      use27bFast
    ];

    # --mlock needs unlimited memlock
    systemd.services = {
      llama-cpp = {
        conflicts = [
          "llama-cpp-27b.service"
          "llama-cpp-27b-fast.service"
        ];
        serviceConfig = {
          LimitMEMLOCK = "infinity";
          RestartSec = lib.mkForce "10s";
        };
      };

      # Manual experiment companions for pius. These are intentionally not
      # wantedBy-enabled: dense 27B is too slow for default CPU-only service
      # use, but useful to keep around for quality and runtime comparisons.
      #   llm-use-27b  # switches llm.vaz.ovh to 27B Hauhau Balanced Q4
      #   llm-use-27b-fast  # same model, all 6 cores for faster prompt ingest
      #   llm-use-35b  # switches back to the daily 35B-A3B service
      llama-cpp-27b = companionService {
        description = "LLaMA C++ server - Hauhau Qwen3.6 27B Balanced";
        alias = model27b;
        conflicts = [
          "llama-cpp.service"
          "llama-cpp-27b-fast.service"
        ];
      };

      llama-cpp-27b-fast = companionService {
        description = "LLaMA C++ server - Hauhau Qwen3.6 27B Balanced fast all-core";
        alias = model27bFast;
        conflicts = [
          "llama-cpp.service"
          "llama-cpp-27b.service"
        ];
        threads = fastThreads;
        allowedCpus = fastCpus;
        slice = "system.slice";
      };
    };
  };
}
