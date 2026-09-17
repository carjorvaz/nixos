{
  self,
  config,
  lib,
  modulesPath,
  pkgs,
  ...
}:

let
  # USB Ethernet (Realtek r8152). The onboard RJ45 is BMC-only (NC-SI sideband);
  # the host has no wired NIC of its own.
  iface = "enp0s20f0u5";

  qwenRuntimeRoot = "/persist/qwen38-sm75";
  qwenPackage = pkgs.qwen38-sm75.override {
    nvidiaPackage = config.hardware.nvidia.package;
  };
  modelAlias = "qwen3.8-27b";

  # Tailnet-only; `tailscale.nix` treats tailscale0 as trusted.
  qwenPort = 8080;

  # The first request pays a one-off graph/draft capture cost that the built-in
  # empty warmup does not cover, and the first *long* prefill compiles the
  # Turing prefill-tile and GDN chunk kernels at their serving shape, which the
  # tiny chat warmup never reaches. A separate, bounded unit absorbs both,
  # largest first, without holding multi-user.target or making server
  # availability depend on warmup. The 2000-word body exercises the 2048-token
  # prefill batch; the chat body then captures the MTP decode graphs.
  qwenWarmupPrefillBody = pkgs.writeText "qwen-warmup-prefill.json" (
    builtins.toJSON {
      model = modelAlias;
      messages = [
        {
          role = "user";
          content = builtins.concatStringsSep " " (
            lib.genList (_: "alpha bravo charlie delta echo foxtrot golf hotel india juliet") 200
          );
        }
      ];
      max_tokens = 1;
      chat_template_kwargs.enable_thinking = false;
    }
  );

  qwenWarmupBody = pkgs.writeText "qwen-warmup.json" (
    builtins.toJSON {
      model = modelAlias;
      messages = [
        {
          role = "user";
          content = "Write a Python function that squares each integer in a list.";
        }
      ];
      max_tokens = 64;
      chat_template_kwargs.enable_thinking = false;
    }
  );

  qwenWarmup = ''
    set -eu
    url="http://127.0.0.1:${toString qwenPort}/v1/chat/completions"
    until ${pkgs.curl}/bin/curl -fs -m 5 -o /dev/null "http://127.0.0.1:${toString qwenPort}/health"; do
      ${pkgs.coreutils}/bin/sleep 5
    done
    ${pkgs.curl}/bin/curl -fsS -m 1200 -o /dev/null \
      -H Content-Type:application/json --data @${qwenWarmupPrefillBody} "$url"
    ${pkgs.curl}/bin/curl -fsS -m 1200 -o /dev/null \
      -H Content-Type:application/json --data @${qwenWarmupBody} "$url"
  '';

in
{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
    "${self}/profiles/nixos/base.nix"
    "${self}/profiles/nixos/server.nix"
    "${self}/profiles/nixos/bootloader/systemd-boot.nix"
    "${self}/profiles/nixos/gpu/nvidia.nix"
    "${self}/profiles/nixos/ninfer-qwen.nix"
    "${self}/profiles/nixos/cpu/intel.nix"
    "${self}/profiles/nixos/ssh.nix"
    "${self}/profiles/nixos/zramSwap.nix"
    # STATE: sudo tailscale up (first auth is manual)
    "${self}/profiles/nixos/tailscale.nix"
  ];

  boot = {
    # Stock kernel/zfs pair from cache.nixos.org — deliberate choice: the
    # CachyOS server-lto kernel has no substituter and building it for this
    # host was not worth the pain (7 GB RAM box; remote-build detours via
    # pius/trajanus shelved). The remote builders stay wired and proven for
    # everything else. To flip later: delete the two mkForce lines, build
    # kernelPackages.zfs_cachyos on a builder, `nix copy` the closure back,
    # then `nixos-rebuild switch`.
    kernelPackages = lib.mkForce pkgs.linuxPackages;
    zfs.package = lib.mkForce pkgs.zfs;
    initrd.availableKernelModules = [
      "xhci_pci"
      "ahci"
      "nvme"
      "usb_storage"
      "sd_mod"
    ];
    zfs.extraPools = [ "zdata" ];
    # 7.5 GB of RAM, a ZFS root, and an 18.5 GB mmapped GGUF: the default ARC
    # target (50% of RAM, measured 4.4 GB here) competes directly with the page
    # cache that keeps the model mapped and with llama.cpp's host-side buffers.
    # Cap it at 1.5 GB — the same lever trajanus uses via kernelParams.
    kernelParams = [ "zfs.zfs_arc_max=1610612736" ];
    # The model loader streams 18.5 GB through the page cache; at the kernel
    # defaults the reclaim watermark is too small for that scan and the box goes
    # OOM. Keep a 512 MB reserve and reclaim earlier (watermark_scale_factor).
    kernel.sysctl = {
      "vm.min_free_kbytes" = lib.mkForce 524288;
      "vm.watermark_scale_factor" = lib.mkForce 200;
    };
  };

  networking = {
    hostName = "tiberius";
    hostId = "5eed08d7";
    # Global useDHCP defaults to true, which lets dhcpcd claim every interface
    # and silently ignores per-interface static addresses.
    useDHCP = false;
    defaultGateway = "192.168.1.1";
    nameservers = [ "192.168.1.1" ];
    # Static in the low zone next to the remoteUnlock .2 precedent: the router
    # DHCP pool demonstrably covers .140-.217, so "next to trajanus" (.172)
    # would collide. Wake path is the BMC, not the NIC: the USB NIC cannot
    # signal wake, so power-on goes through IPMI (ipmitool -I lanplus ...).
    interfaces.${iface} = {
      useDHCP = false;
      ipv4.addresses = [
        {
          address = "192.168.1.3";
          prefixLength = 24;
        }
      ];
    };
  };

  # Runtime generations, pinned checkpoints and JIT caches live directly on the
  # persistent filesystem; no mutable runtime is copied through the Nix store.
  environment.systemPackages = [ qwenPackage ];

  # A driver Xid storm fills the journal until the unit's own logs are evicted.
  # Keep the journal on disk with a much larger burst so an incident leaves
  # evidence; the impermanent root means it does not accumulate across boots.
  services.journald = {
    storage = "persistent";
    extraConfig = ''
      RateLimitIntervalSec=10s
      RateLimitBurst=200000
      SystemMaxUse=2G
    '';
  };
  systemd.services = {
    # Keep NInfer available for manual fallback, but boot into vLLM. Never let
    # both resident engines contend for the single GPU or the API port.
    tiberius-ninfer = {
      wantedBy = lib.mkForce [ ];
      conflicts = [ "tiberius-qwen38.service" ];
    };

    # The card is factory-capped at 250 W and supports 280 W; under vLLM load
    # it drew 245 W at ~1724 MHz at the cap and 273-287 W at 1680-1800 MHz
    # unlocked. The campaign's same-window measurement read +1.6% on the agent
    # suite (inside the +/-4% single-run band) with the clock rise measured
    # independently. The limit reverts to 250 W on every driver load, so it is
    # re-applied here rather than left to a one-off nvidia-smi call.
    tiberius-gpu-power-limit = {
      description = "Raise the RTX 2080 Ti power limit to its 280 W maximum";
      wantedBy = [ "multi-user.target" ];
      after = [ "nvidia-persistenced.service" ];
      requires = [ "nvidia-persistenced.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${lib.getBin config.hardware.nvidia.package}/bin/nvidia-smi -i 0 -pl 280";
      };
    };

    # A storm of Xid lines (hundreds per sampling window) means the GPU
    # channel is wedged: the engine cannot make progress and the driver floods
    # the journal with preemption retries. Stopping the engine releases the
    # channel it owns and keeps the exchange readable. Single Xid lines are
    # ignored; the threshold is deliberately far above transient noise.
    tiberius-gpu-xid-watch = {
      description = "Stop the inference engine on a GPU Xid storm";
      wantedBy = [ "multi-user.target" ];
      after = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        Restart = "always";
        RestartSec = "30s";
        ExecStart = pkgs.writeShellScript "tiberius-xid-watch" ''
          set -u
          prev=0
          while true; do
            now=$(${pkgs.util-linux}/bin/dmesg 2>/dev/null | ${pkgs.gnugrep}/bin/grep -c Xid || true)
            if [ "$now" -lt "$prev" ]; then
              delta=0 # ring buffer wrapped; rebaseline
            else
              delta=$((now - prev))
            fi
            prev=$now
            if [ "$delta" -gt 100 ]; then
              ${pkgs.util-linux}/bin/logger -t tiberius-xid-watch "Xid storm: +$delta lines; stopping inference engines"
              ${config.systemd.package}/bin/systemctl stop tiberius-qwen38.service tiberius-qwen38-uncensored.service tiberius-ninfer.service 2>/dev/null || true
              sleep 300
            fi
            sleep 30
          done
        '';
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
      };
    };

    tiberius-qwen38-prepare = {
      description = "Prepare the pinned Qwen3.8 Turing runtime and checkpoints";
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      unitConfig.RequiresMountsFor = qwenRuntimeRoot;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${qwenPackage}/bin/qwen38-sm75-prepare ${qwenRuntimeRoot}";
        TimeoutStartSec = "infinity";
        MemoryHigh = "2G";
        MemoryMax = "3G";
        MemorySwapMax = "512M";
        UMask = "0077";
      };
    };

    # Optional second model: the uncensored W4A16 checkpoint, staged under
    # /data (the persistent pool is full with the production model). It is
    # never enabled at boot; start it by hand, Conflicts takes the production
    # engine down first. Scope: its int8 lm_head/embed and bf16 MTP head make
    # it measurably slower than the calibrated fast variant, so this unit is
    # for evaluating the different weights, not as a drop-in replacement.
    tiberius-qwen38-uncensored-prepare = {
      description = "Prepare the optional uncensored Qwen3.8 checkpoint";
      wants = [ "network-online.target" ];
      after = [
        "network-online.target"
        "tiberius-qwen38-prepare.service"
      ];
      requires = [ "tiberius-qwen38-prepare.service" ];
      unitConfig.RequiresMountsFor = [ "/data" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${qwenPackage}/bin/qwen38-sm75-prepare-uncensored /data/qwen38-uncensored";
        TimeoutStartSec = "infinity";
        MemoryHigh = "512M";
        MemoryMax = "1G";
        MemorySwapMax = "256M";
        UMask = "0077";
      };
    };

    tiberius-qwen38-uncensored = {
      description = "Qwen3.8-27B uncensored on the RTX 2080 Ti (optional, port 8082)";
      conflicts = [
        "tiberius-qwen38.service"
        "tiberius-ninfer.service"
      ];
      requires = [ "tiberius-qwen38-uncensored-prepare.service" ];
      after = [
        "tiberius-qwen38-uncensored-prepare.service"
        "nvidia-persistenced.service"
        "tiberius-ninfer.service"
      ];
      unitConfig.RequiresMountsFor = [ "/data" ];
      environment = {
        QWEN_RUNTIME_ROOT = qwenRuntimeRoot;
        OMP_NUM_THREADS = "1";
        VLLM_GDN_DECODE_KERNEL = "triton";
        FLA_TRIL_PRECISION = "ieee";
        VLLM_USE_FLASHINFER_SAMPLER = "0";
        FLASHINFER_DISABLE_VERSION_CHECK = "1";
        VLLM_SPEC_DECODE_ATTN = "1";
        VLLM_SPEC_DECODE_ATTN_QMAX = "8";
        VLLM_DRAFT_TOPK_TOPP = "1";
        # The hybrid checkpoint below carries a 40k-row int8 draft head built
        # from its own lm_head by pkgs/qwen38-sm75/build-draft-head.py; without
        # it every draft pass reads the full 248k-row int8 lm_head and decode
        # is about 30% slower.
        MTP_DRAFT_VOCAB = "1";
        PYTORCH_ALLOC_CONF = "expandable_segments:True";
        VLLM_ENGINE_STALL_SENTINEL_S = "120";
      };
      serviceConfig = {
        Type = "exec";
        # Optional operator overrides, e.g. VLLM_MARLIN_INPUT_DTYPE=int8
        # with VLLM_MARLIN_INT8_INCLUDE_RE for a prefill-heavy profile, or
        # VLLM_TURING_SPEC_NSEG for a split-KV segment sweep. Absent by
        # default; unit Environment= still supplies the validated values.
        EnvironmentFile = "-${qwenRuntimeRoot}/serve.env";
        ExecStart = "${qwenPackage}/bin/qwen38-sm75-serve ${
          lib.escapeShellArgs [
            "/data/qwen38-uncensored/models/hybrid-dv8-mtp4c"
            "--served-model-name"
            "qwen3.8-27b-uncensored"
            "--host"
            "0.0.0.0"
            "--port"
            "8082"
            "--dtype"
            "float16"
            "--language-model-only"
            "--attention-backend"
            "TRITON_ATTN"
            "--kv-cache-dtype"
            "int4_per_token_head"
            "--mamba-cache-dtype"
            "float16"
            "--mamba-ssm-cache-dtype"
            "float16"
            # Its int8 lm_head/embed and bf16 MTP head are ~1 GiB heavier
            # than the fast variant; 4.5 GiB KV is what fits at 235k context.
            "--kv-cache-memory"
            "4831838208"
            "--max-model-len"
            "235000"
            "--max-num-seqs"
            "1"
            "--max-num-batched-tokens"
            "2048"
            "--enable-prefix-caching"
            "--prefix-match-unit"
            "16"
            "--mamba-cache-mode"
            "align"
            "--speculative-config"
            (builtins.toJSON {
              method = "mtp";
              num_speculative_tokens = 4;
              draft_sample_method = "probabilistic";
              attention_backend = "TRITON_ATTN";
            })
            "--compilation-config"
            (builtins.toJSON {
              mode = "VLLM_COMPILE";
              cudagraph_mode = "FULL_AND_PIECEWISE";
              max_cudagraph_capture_size = 8;
              custom_ops = [
                "+rms_norm"
                "+silu_and_mul"
              ];
            })
            "--async-scheduling"
            "--load-format"
            "runai_streamer"
            "--model-loader-extra-config"
            (builtins.toJSON {
              memory_limit = 1610612736;
              concurrency = 2;
            })
            "--default-chat-template-kwargs"
            (builtins.toJSON { reasoning_effort = "medium"; })
            "--reasoning-parser"
            "qwen3"
            "--enable-auto-tool-choice"
            "--tool-call-parser"
            "qwen3_coder"
            "--enable-prompt-tokens-details"
            "--sse-keep-alive-interval"
            "30"
          ]
        }";
        Restart = "no";
        TimeoutStopSec = "30s";
        LimitMEMLOCK = "infinity";
        MemoryHigh = "5G";
        MemoryMax = "6G";
        MemorySwapMax = "1G";
        UMask = "0077";
      };
    };

    tiberius-qwen38 = {
      description = "Qwen3.8-27B on the RTX 2080 Ti (vLLM)";
      wantedBy = [ "multi-user.target" ];
      conflicts = [ "tiberius-ninfer.service" ];
      requires = [ "tiberius-qwen38-prepare.service" ];
      after = [
        "tiberius-qwen38-prepare.service"
        "nvidia-persistenced.service"
        # Conflicts alone does not order shutdown before GPU acquisition.
        "tiberius-ninfer.service"
      ];
      unitConfig.RequiresMountsFor = qwenRuntimeRoot;
      environment = {
        QWEN_RUNTIME_ROOT = qwenRuntimeRoot;
        OMP_NUM_THREADS = "1";
        VLLM_GDN_DECODE_KERNEL = "triton";
        FLA_TRIL_PRECISION = "ieee";
        VLLM_USE_FLASHINFER_SAMPLER = "0";
        FLASHINFER_DISABLE_VERSION_CHECK = "1";
        VLLM_SPEC_DECODE_ATTN = "1";
        VLLM_SPEC_DECODE_ATTN_QMAX = "8";
        MTP_DRAFT_VOCAB = "1";
        VLLM_DRAFT_TOPK_TOPP = "1";
        PYTORCH_ALLOC_CONF = "expandable_segments:True";
        # Warn once if the engine stops completing steps while requests are
        # live. Keys on completed steps, so a chunked prefill (which completes
        # a step per chunk) cannot false-positive however long it runs.
        VLLM_ENGINE_STALL_SENTINEL_S = "120";
      };
      serviceConfig = {
        Type = "exec";
        # Optional operator overrides, e.g. VLLM_MARLIN_INPUT_DTYPE=int8
        # with VLLM_MARLIN_INT8_INCLUDE_RE for a prefill-heavy profile, or
        # VLLM_TURING_SPEC_NSEG for a split-KV segment sweep. Absent by
        # default; unit Environment= still supplies the validated values.
        EnvironmentFile = "-${qwenRuntimeRoot}/serve.env";
        ExecStart = "${qwenPackage}/bin/qwen38-sm75-serve ${
          lib.escapeShellArgs [
            "${qwenRuntimeRoot}/models/target"
            "--served-model-name"
            modelAlias
            # The firewall trusts tailscale0; no LAN/WAN port is opened.
            "--host"
            "0.0.0.0"
            "--port"
            (toString qwenPort)
            "--dtype"
            "float16"
            "--language-model-only"
            "--attention-backend"
            "TRITON_ATTN"
            "--kv-cache-dtype"
            "int4_per_token_head"
            "--mamba-cache-dtype"
            "float16"
            "--mamba-ssm-cache-dtype"
            "float16"
            # Reserve checkpoint/CoW headroom for fine-hash MTP4 at full context.
            "--kv-cache-memory"
            "5905580032"
            "--max-model-len"
            "262144"
            "--max-num-seqs"
            "1"
            # Keep the validated MTP4/INT4 prefill page-aligned (1632 tokens).
            "--max-num-batched-tokens"
            "2048"
            "--enable-prefix-caching"
            # Hash granularity is independent of the 1632-token physical page.
            "--prefix-match-unit"
            "16"
            "--mamba-cache-mode"
            "align"
            "--speculative-config"
            (builtins.toJSON {
              method = "mtp";
              num_speculative_tokens = 4;
              draft_sample_method = "probabilistic";
              attention_backend = "TRITON_ATTN";
            })
            "--compilation-config"
            (builtins.toJSON {
              mode = "VLLM_COMPILE";
              cudagraph_mode = "FULL_AND_PIECEWISE";
              max_cudagraph_capture_size = 8;
              custom_ops = [
                "+rms_norm"
                "+silu_and_mul"
              ];
            })
            "--async-scheduling"
            "--load-format"
            "runai_streamer"
            "--model-loader-extra-config"
            (builtins.toJSON {
              memory_limit = 1610612736;
              concurrency = 2;
            })
            # Avoid the checkpoint template's implicit xhigh for API clients
            # that omit effort. Explicit per-request low/xhigh still wins.
            "--default-chat-template-kwargs"
            (builtins.toJSON { reasoning_effort = "medium"; })
            "--reasoning-parser"
            "qwen3"
            "--enable-auto-tool-choice"
            "--tool-call-parser"
            "qwen3_coder"
            "--enable-prompt-tokens-details"
            # SSE comment lines every 30 s while a stream is idle, so a proxy
            # or tunnel with an idle timeout cannot drop a multi-minute cold
            # prefill before the first token (upstream vLLM #51034).
            "--sse-keep-alive-interval"
            "30"
          ]
        }";
        Restart = "always";
        RestartSec = "15s";
        TimeoutStopSec = "30s";
        LimitMEMLOCK = "infinity";
        # Keep an inference or loader failure inside this 7.5 GB host's cgroup.
        MemoryHigh = "5G";
        MemoryMax = "6G";
        MemorySwapMax = "1G";
        UMask = "0077";
      };
    };

    tiberius-qwen38-warmup = {
      description = "Warm the Qwen speculative inference graph";
      wantedBy = [ "tiberius-qwen38.service" ];
      after = [ "tiberius-qwen38.service" ];
      bindsTo = [ "tiberius-qwen38.service" ];
      partOf = [ "tiberius-qwen38.service" ];
      script = qwenWarmup;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # Expiry or a failed request stops only warmup, never the server.
        TimeoutStartSec = "25min";
        DynamicUser = true;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
      };
    };
  };

  # Remote builders are reached by the nix daemon (not by an interactive ssh
  # session), and the root filesystem rolls back on every boot: without
  # declarative host keys the daemon fails with "Host key verification failed",
  # silently falls back to building locally, and a full-parallel CUDA build on
  # this 7.5 GB box takes the whole host down with it.
  programs.ssh.knownHosts = {
    pius.publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKAJul712iSthWHXLAgBh38x4lpjXgsTd2KzlP5Jnf55";
    trajanus.publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPGoGQXDEcTd0T72g+YRzoQO30E09BvbfD9eBtcl3NRf";
  };

  nix = {
    settings.builders = [ "@/etc/nix/machines" ];
    distributedBuilds = true;
    # Builders over the tailnet; reachable once `sudo tailscale up` has run.
    buildMachines = [
      {
        # pius first: trajanus is disk-full and its daemon dies mid-build.
        hostName = "pius";
        sshUser = "nix-ssh";
        sshKey = "/persist/etc/ssh/builder@tiberius";
        systems = [ "x86_64-linux" ];
        protocol = "ssh-ng";
        maxJobs = 6;
        speedFactor = 2;
        supportedFeatures = [
          "nixos-test"
          "benchmark"
          "big-parallel"
          "kvm"
        ];
      }
      {
        hostName = "trajanus";
        sshUser = "nix-ssh";
        sshKey = "/persist/etc/ssh/builder@tiberius";
        systems = [ "x86_64-linux" ];
        protocol = "ssh-ng";
        maxJobs = 8;
        speedFactor = 3;
        supportedFeatures = [
          "nixos-test"
          "benchmark"
          "big-parallel"
          "kvm"
        ];
      }
      {
        hostName = "pius";
        sshUser = "nix-ssh";
        sshKey = "/persist/etc/ssh/builder@tiberius";
        systems = [ "x86_64-linux" ];
        protocol = "ssh-ng";
        maxJobs = 6;
        speedFactor = 2;
        supportedFeatures = [
          "nixos-test"
          "benchmark"
          "big-parallel"
          "kvm"
        ];
      }
    ];
    settings.trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "tiberius-builder-pius:Q6Ykvkqf0OoLCFqNMwjCns04A8OK+sOaZK0Tmy7ZMRE="
      "tiberius-builder-trajanus:njMvtYYB/ZQbSrjzquwrsuaclPHvIVxLmtJ1bPdyJOU="
    ];
  };

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  system.stateVersion = "26.05";
}
