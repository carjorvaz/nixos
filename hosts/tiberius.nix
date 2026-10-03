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
    # Unimported 2026-09-19: ninfer-sm75 no longer builds (dies in the fixup
    # phase after ~1h26m with the daemon disconnecting), which blocks every
    # configuration build for this host. Restore together with the service
    # override below once the package builds again.
    # "${self}/profiles/nixos/ninfer-qwen.nix"
    "${self}/profiles/nixos/cpu/intel.nix"
    "${self}/profiles/nixos/ssh.nix"
    "${self}/profiles/nixos/zramSwap.nix"
    # STATE: sudo tailscale up (first auth is manual)
    "${self}/profiles/nixos/tailscale.nix"
    # Strata (IQ3_S) on the Optane PMEM: engine from pkgs/strata-sm75, the
    # fsdax/XFS mount, and the server unit; conflicts with the vLLM lanes.
    "${self}/profiles/nixos/strata.nix"
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
    # DMA-from-pmem experiment: allow FSDAX long-term pins (device DMA straight
    # out of the Optane pmem, no bounce copy) for this kernel only.  The patch
    # adds an opt-in flag that defaults OFF; the param below turns it on.
    # UNSAFE on general filesystems (fsdax pages cannot be migrated, truncated
    # or hot-unplugged while pinned); fine here because the engine only ever
    # pins a read-only, never-truncated experts.bin on a permanently attached
    # /dev/pmem0.  Revert: drop this block and the fsdax_longterm_pin param.
    kernelPatches = [
      {
        name = "fsdax-longterm-pin";
        patch = ../pkgs/kernel-patches/fsdax-longterm-pin.patch;
      }
    ];
    # 7.5 GB of RAM, a ZFS root, and an 18.5 GB mmapped GGUF: the default ARC
    # target (50% of RAM, measured 4.4 GB here) competes directly with the page
    # cache that keeps the model mapped and with llama.cpp's host-side buffers.
    # Cap it at 1.5 GB — the same lever trajanus uses via kernelParams.
    # fsdax_longterm_pin=1 is the companion of the kernel patch above; without
    # it the kernel behaves exactly like stock (pins of fsdax VMAs are still
    # rejected with -EOPNOTSUPP).
    kernelParams = [
      "zfs.zfs_arc_max=1610612736"
      "fsdax_longterm_pin=1"
      # The BMC's SOL was blind during the 2026-10-01 lockout (no console= at
      # all, so only firmware output would ever appear).  A serial console makes
      # SOL a real console: kernel/systemd logs plus a serial getty for login.
      "console=tty0"
      "console=ttyS0,115200n8"
      "console=ttyS1,115200n8"
    ];
    # The model loader streams 18.5 GB through the page cache; at the kernel
    # defaults the reclaim watermark is too small for that scan and the box goes
    # OOM. Keep a 512 MB reserve and reclaim earlier (watermark_scale_factor).
    # sysrq is armed so the Xid-storm watchdog can force a kernel-level reboot
    # when a wedged GPU prevents the normal shutdown path from completing.
    kernel.sysctl = {
      "kernel.sysrq" = 1;
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
    # Parked with the profile import above (the unit no longer exists without
    # it). The `conflicts`/`after` references to it elsewhere in this file stay
    # as bare names, which systemd accepts for absent units.
    # tiberius-ninfer = {
    #   wantedBy = lib.mkForce [ ];
    #   conflicts = [ "tiberius-qwen38.service" ];
    # };

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
              ${config.systemd.package}/bin/systemctl stop tiberius-strata.service tiberius-qwen38.service tiberius-qwen38-uncensored.service tiberius-ninfer.service 2>/dev/null || true
              sleep 60
              after=$(${pkgs.util-linux}/bin/dmesg 2>/dev/null | ${pkgs.gnugrep}/bin/grep -c Xid || true)
              if [ "$after" -gt "$((now + 100))" ]; then
                # The storm outlived the engine: the driver is wedged, and the
                # normal shutdown path is known to hang here. Force a reboot.
                ${pkgs.util-linux}/bin/logger -t tiberius-xid-watch "Xid storm continues after engine stop; forcing reboot"
                echo b > /proc/sysrq-trigger
              fi
              prev=$after
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

    # Optional second model: the uncensored W4A16 checkpoint, staged beside the
    # production one under /persist. Never enabled at boot, and it can never run
    # at the same time as the production engine: both are ~20 GB on a 22 GB card,
    # so the serve unit below conflicts with production and is ordered after its
    # shutdown. Scope: it is the
    # Orca abliteration (orcarouter lineage, independently verified) requantized
    # W4A16 with int4/GPTQ-calibrated heads, so prefill and per-step time match
    # the production target; it decodes ~24% fewer tokens per second purely
    # because its abliterated MTP head accepts fewer drafts (2.7 vs ~4.2 tokens
    # per step). Not a drop-in: a smarter draft head, not a dtype change, is what
    # would close that. Its own speculative optimum is MTP3, not MTP4.
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
        # Same root as the production prepare unit: the uncensored checkpoint is
        # staged beside the production one under /persist, not under /data (which
        # held the retired hybrid lane and did not have room for a second model).
        ExecStart = "${qwenPackage}/bin/qwen38-sm75-prepare-uncensored ${qwenRuntimeRoot}";
        TimeoutStartSec = "infinity";
        MemoryHigh = "512M";
        MemoryMax = "1G";
        MemorySwapMax = "256M";
        UMask = "0077";
      };
    };

    tiberius-qwen38-uncensored = {
      description = "Qwen3.8-27B uncensored on the RTX 2080 Ti (alternative lane)";
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
        # Turing port: propose the whole draft block from the request's own
        # history when the context repeats (copy/edit work) and skip the
        # drafter; greedy requests only, and only after a fully accepted step.
        VLLM_MTP_LOOKUP = "1";
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
            "/persist/qwen38-sm75/models/uncensored"
            "--served-model-name"
            # Same port and model name as the production unit on purpose: the two
            # can never run together (both are ~20 GB on a 22 GB card), so serving
            # the same slot makes a flip invisible to clients - only the weights
            # change. The unit conflicts with production and is ordered after its
            # shutdown, and it is not enabled at boot.
            modelAlias
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
            # Same KV and context budget as the production unit: this
            # checkpoint was measured booting under those exact flags at 20.9 GB
            # (it carries int4 lm_head/embed and its own MTP draft vocabulary).
            "--kv-cache-memory"
            "5905580032"
            "--max-model-len"
            "262144"
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
              # Measured on the 0.29.0 runtime (V2 runner, MTP history lookup):
              # 112.8 / 105.1 tok/s at 8k / 32k and 104.7 on the 32k-word copy,
              # against MTP3's 104.3 / 89.1 / 87.9 and MTP5's 116.3 / 93.5 /
              # 98.2. The 4th draft position accepts enough to pay for itself;
              # width past that only wins at short context. Earlier numbers on
              # the 0.28 stack had MTP3 ahead, which is why this was 3.
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
      # Strata is the boot engine on this host (services.tiberius-strata); the
      # lane stays installed for A/B and fallback.  To flip back: make this
      # [ "multi-user.target" ] and set services.tiberius-strata.enable = false.
      wantedBy = lib.mkForce [ ];
      # Symmetric with the uncensored lane: either start takes the other down,
      # so toggling in either direction cannot leave two engines on one 22 GB
      # card (which fails the second one with a memory error).
      conflicts = [
        "tiberius-ninfer.service"
        "tiberius-qwen38-uncensored.service"
      ];
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
        # Turing port: propose the whole draft block from the request's own
        # history when the context repeats (copy/edit work) and skip the
        # drafter; greedy requests only, and only after a fully accepted step.
        VLLM_MTP_LOOKUP = "1";
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
            # Two 1632-token pages per prefill chunk: the scheduler caps at
            # 3264 here, which halves the per-chunk repack and launch overhead
            # against 2048 (measured on the Turing stack, 2026-09-24).
            "--max-num-batched-tokens"
            "4096"
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

  # Strata (Qwen3.8-Flash-Next IQ3_S) is the default engine on this host: the
  # experts are mmapped from the Optane PMEM (126 GiB fsdax, dax=always) and the
  # 262K-context int8-KV configuration measures 20-21 tok/s decode and 457-1034
  # tok/s prefill (4.3K-27.5K tokens; the lane note below has the exact cells).
  # The vLLM lanes below stay installed for A/B and fallback; flip
  # their wantedBy back to [ "multi-user.target" ] to make one the boot engine
  # (both sides conflict, so only one ever holds the GPU).
  services.tiberius-strata = {
    enable = true;
    package = pkgs.strata-sm75;
    # IQ3_S is the served lane, by choice: it is the quality pack (24,576
    # experts, "matches the full model") and this box exists to run it.  The
    # Coder lane (model = "coder") stays one option away and is faster - measured
    # 2026-10-03 at 131072 context: 1.73x/1.12x its prefill and 1.66x/1.63x its
    # decode of IQ3_S (790.7/1129.9 tok/s prefill, 39.6/34.3 tok/s decode at
    # 4344/27575 tokens, 94.1/91.3% hit vs 456.6/1004.5 and 23.9/21.0 at
    # 82.6/81.8%) - but it halves the expert count and trades quality (91.3% of
    # the full model's SWE-bench Verified, weaker outside code including CJK).
    # Not taken on purpose.
    model = "iq3-s";
    # 262K is the model's trained window (qwen4exp.context_length) and the engine
    # runs --rope-scaling none, so nothing above it is valid.  Measured on this box
    # 2026-10-03 (deployed v0.1.35 stack, fresh engine per cell, 128-token replies,
    # k8v4): every +64K of context costs 0.78 GiB of VRAM and ~414 expert-cache
    # slots (7487 -> 6657 at 262K), and buys -3.4 points of hit, -10..-15% of decode
    # (21.5 -> 19.4 tok/s at a 14K prompt, 20.9 -> 17.8 at 110K) and -6% of prefill
    # (~660 -> 622 tok/s, +11 s on a 110K prompt).  Prefill is ~flat in prompt
    # length (644-706 tok/s from 14K to 110K, so a 110K prompt is ~2.8 min), which
    # makes the decode delta ~1 s on a 128-token reply - invisible next to TTFT -
    # while the extra 131K of window is exactly what agent traffic consumes.  Do not
    # go further: at 524K the hit rate is 70% and decode 14.5 tok/s, at 786K 54% and
    # 10.6; q4_0 only changes the far, unusable end (and costs 12-15% of prefill).
    context = 262144;
    # The namespace is already fsdax and formatted; the prepare unit is a no-op.
    formatOptane = false;
    # KV cache: int8 (K and V both INT8 with FP16 scales) is the highest precision
    # that costs almost nothing at this context - k8v4 stores V as Hadamard-rotated
    # Q4_0.  Measured 2026-10-03 (fresh engines, 256 gen): int8 costs 369 expert
    # slots (-5.5%, 6288 vs 6657), 1.7 pts of hit, and -5.1% / -7.6% decode at
    # 4344 / 27575 tokens pre-rotation (a further -0.83% / -0.96% on identical
    # streams once the rotation below is on); its larger cells also shrink the
    # prompt chunk the engine can borrow for, which is why --prefill asks 28160
    # (the largest value accepted without halving; the old 28672 was silently
    # halved to 14336 and cost 12.7% of the long-prompt read).  The module sets
    # STRATA_KV_ROT=1 for this lane: both K and V go through the Hadamard
    # rotation, which with the expert set pinned cuts the near-tie KL against
    # fp16 6.6x (0.524 -> 0.0798) and restores its top-1 where unrotated int8
    # flips, for zero capacity and ~1% decode (measured 2026-10-03, /data/kvrot).
    # fp16 is the absolute ceiling
    # and is priced too: 4607 slots and ~-23% decode at 262144, or - with no
    # speed cost at all - 6464 slots and the full chunk at 131072; not taken here.
    kv = "int8";
  };

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  system.stateVersion = "26.05";
}
