{
  config,
  lib,
  pkgs,
  ...
}:

# Strata (Qwen3.8-Flash-Next) on the Optane PMEM, two model lanes:
#
#   * `coder`  -- the Coder IQ1_M release: half the experts (12,288), coding/
#                 tool/vision-pruned.  The measured default on tiberius:
#                 ~35 tok/s decode at 94% VRAM expert hit, ~410 tok/s prefill
#                 for a fresh 2.2K prompt, 92% hit and ~29 tok/s at 262K.
#   * `iq3-s`  -- the original IQ3_S (24,576 experts, "matches the full model"):
#                 ~20-32 tok/s decode (cache-warmth dependent) and ~269 tok/s
#                 prefill for a 2.3K prompt / 388 for 4.1K (131K context).
#                 With the hosted Optane's copies as the pacer, prefill is
#                 bounded by the non-resident expert bytes per chunk.
#
# The engine is built for sm_75 by pkgs/strata-sm75 (with the local engine patch:
# the host expert tier and the sliding DAX window); the model itself is NOT in the
# store -- it was prepared once on the host (the setup flow's iq_pack step) and
# lives on the DAX-mounted Optane.  This module wires up:
#
#   * the fsdax namespace + XFS(dax=always) mount (idempotent prepare unit),
#   * the OpenAI/Anthropic server over serve/server.py with the measured flags
#     (mmap experts from the Optane, K8V4 KV, MTP4 + suffix drafts, the
#     layer-order staging ring at 4, the rank-capped host expert tier, and the
#     6144 MiB sliding DAX window that DMA-copies the streaming layer),
#   * the driver's libcuda.so.1 on the loader path and LimitMEMLOCK=infinity,
#   * conflicts with the vLLM services: both want the single GPU.
#
# The one destructive knob is formatOptane: the prepare unit refuses to touch a
# namespace or a filesystem it does not recognise unless it is set.
let
  cfg = config.services.tiberius-strata;

  python = pkgs.python312.withPackages (ps: [
    ps.regex
    ps.numpy
    ps.requests
    # serve/ imports these directly: jinja2.sandbox (chat templates), PIL (vision),
    # psutil (the engine-supervision/telemetry path).
    ps.jinja2
    ps.pillow
    ps.psutil
  ]);

  lanes = {
    coder = {
      pack = "coder-iq1_m";
      models = "coder-IQ1_M";
      shard1 = "Qwen3.8-Flash-Next-GSQ-RCO-IQ1_M-00001-of-00002.gguf";
      profile = "expert-profile-coder.bin";
      modelName = "qwen3.8-flash-next-coder-iq1_m";
      defaultContext = 131072;
    };
    iq3-s = {
      pack = "iq3_s";
      models = "IQ3_S";
      shard1 = "Qwen3.8-Flash-Next-GSQ-RCO-IQ3_S-00001-of-00002.gguf";
      profile = "expert-profile.bin";
      modelName = "qwen3.8-flash-next-iq3_s";
      defaultContext = 262144;
    };
  };
  lane = lanes.${cfg.model};

  strataJson = pkgs.writeText "strata-${cfg.model}.json" (
    builtins.toJSON {
      exe = "${cfg.package}/bin/strata";
      args = [
        "--pack"
        "${cfg.dataDir}/packs/${lane.pack}"
        "--native"
        "${cfg.modelsRoot}/${lane.models}/${lane.shard1}"
        "--ple-gguf"
        # Shared by both lanes on purpose: the PLE table (shard 2) is common to
        # the IQ3_S and Coder releases, and the coder has no shard 2 of its own
        # (verified 2026-09-30 on the box: /optane/strata-data/ple/ holds only
        # this file and the coder's models dir holds only its shard 1).  The
        # engine appends this shard to the dense tensors, which is exactly what
        # the manually-measured coder lane at 410 tok/s prefill used.
        "${cfg.dataDir}/ple/Qwen3.8-Flash-Next-GSQ-RCO-IQ3_S-00002-of-00002.gguf"
        "--ple-io"
        "mmap"
        "--expert-profile"
        "${cfg.package}/share/strata/data/${lane.profile}"
        "--expert-cache"
        "auto"
        "--prefill"
        "auto"
        "--spec"
        "4"
        "--spec-min-p"
        "0.5"
        "--mtp"
        "${cfg.dataDir}/mtp/rt"
        "--max-context"
        (toString cfg.context)
        "--kv"
        cfg.kv
        "--mmap-experts"
        "--resident-cpu-experts"
        "--resident-cpu-mib"
        (toString cfg.hostTierMib)
        # tiberius: no --adapt-swaps here on purpose.  The adaptive VRAM refill
        # runs on the decode loop's critical path (`adapt_thr.join()`, 15.8-16.0%
        # of every decode window at the engine's default 96 swaps, 0.76-0.85 ms
        # per swapped expert), but cutting it to 48 does not pay: the cheaper join
        # costs 3.8/3.2 points of decode expert-cache hit rate, i.e. +15.8/+8.3 ms
        # of CPU pool per window against the -9.1/-6.5 ms the join saves.  Measured
        # 2026-10-02 on the deployed engine, counterbalanced medians over 7 runs an
        # arm: wall +6.0%/+1.4% and tok/s -4.2%/-6.4% at 48, a wash at 64.  The
        # apparent win at 48 in an earlier, shorter A/B was the four-window cold
        # warm-up transient, not steady state.  The refill itself is load-bearing:
        # the same measurements put the static profile alone (no eviction, no
        # refill) at 68.3% hit versus 80.1% shipped.
        "--stats"
      ];
      cwd = "${cfg.package}/share/strata";
      tokenizer = "${cfg.dataDir}/packs/${lane.pack}/tokenizer";
      model_name = lane.modelName;
      log = "${cfg.stateDir}/strata-${cfg.model}.log";
      lib_dirs = [ "${config.hardware.nvidia.package}/lib" ];
      env = {
        STRATA_SPLIT_TIMING = "1";
        # tiberius: a small pinned staging ring is ~16% faster on prefill than
        # the default 16 (the copies follow layer order, so a deep ring only
        # adds DMA/cache contention); measured 2026-09-30.
        STRATA_STAGER_RING = "4";
        # tiberius: 8 == the engine's STAGE constant, its opt-in to *routed-only*
        # staging for every chunk size.  The default "stream every non-resident
        # expert of every layer in a fixed order" path (chunks >= 2048 tokens)
        # stages experts the chunk's routing never touches; routed-only stages
        # each layer's routed set just in time.  Measured on real prose
        # (2026-09-30, server path, same nested prefixes): 2409 tok 12.56 ->
        # 10.57 s (192 -> 228 tok/s), 3601 13.05 -> 12.24, 4282 13.51 -> 12.91,
        # 6037 parity (by then both stream ~every expert).  Profiler on the same
        # 5.2K-token document: 18,451 -> 14,939 blobs streamed, 13.7 -> 12.5 s.
        # Never slower; 19% fewer bytes on a long document.
        STRATA_PREFILL_RING = "8";
        # tiberius: the dense GEMMs on the FP16 tensor cores.  Turing has FP16
        # tensor cores and no BF16 ones, so cuBLAS served the dense (non-expert)
        # GEMMs - 482 calls, 335.7 ms of a 9.2 s prompt - with its FP32 SIMT
        # fallback (magma_sgemmEx_kernel).  The flag converts the operand pairs to
        # FP16 (exact for bf16 values in range; measured max|X| 103.5 / max|W|
        # 11.56 against fp16's 65504) and keeps FP32 accumulation, so the
        # prompt-path state hash moves with the accumulation order - hence opt-in,
        # with the engine keeping the BF16 path below 32 rows.  Measured
        # 2026-10-01 on the real corpus, 3 runs/arm, same binary, on vs off:
        # 4292-token prompt 10,350 -> 9,845 ms (-4.9% mean, -5.8% median),
        # 3514-token 9,782 -> 9,179 (-6.2%); total kernel time 1564 -> 1302 ms
        # (-16.8%).  Decode untouched (its only Gemm::bf16 caller runs below the
        # row threshold).
        STRATA_DENSE_FP16 = "1";
        # tiberius: the sliding DAX window.  The kernel opt-in
        # (fsdax_longterm_pin=1, pkgs/kernel-patches/fsdax-longterm-pin.patch) is
        # what lets cudaHostRegister pin DAX pages at all; the driver then caps a
        # PROCESS's total registered host memory, so the engine registers the pack
        # 6144 MiB at a time and slides the window layer by layer as prefill walks
        # the file.  Measured 2026-10-01 on the real corpus: prefill 13,136 ->
        # 10,223 ms for a 4292-token prompt (327 -> 420 tok/s) with 8 rotations
        # over the 48-layer pack, decode unchanged.
        #
        # The cap was probed on 2026-10-02 (/data/regcap*.log): a single 6912 MiB
        # registration succeeds and 7168 MiB is refused with
        # cudaErrorMemoryAllocation, so the limit is ~7 GiB per process - and it is
        # a *total*: disjoint registrations do not escape it, dropping
        # cudaHostRegisterMapped changes nothing, RLIMIT_MEMLOCK is unlimited, and
        # holding anonymous memory does not move it.  The 46.84 GiB pack therefore
        # cannot be pinned in one window and the 8 rotations per prompt are
        # irreducible.  Raising the MIB to 6912 would save at most one rotation
        # (~0.9%) while eating the headroom the engine's own pinned buffers need -
        # and a refused registration makes the engine fall back to the pageable
        # path (13 s prefill) - so 6144 stays.  Nothing here scales with free RAM;
        # the ~7 GiB total looks like the box's lockable-memory budget.
        STRATA_REGISTER_DAX = "1";
        STRATA_REGISTER_DAX_MIB = "6144";
      };
      port = cfg.port;
      # The vLLM lane this replaced bound 0.0.0.0 (and the tailnet profile marks
      # tailscale0 trusted), so clients reach the API as http://tiberius:8080/v1.
      # server.py defaults to 127.0.0.1 when the key is absent, which silently
      # broke remote access after the cutover (found in the 2026-10-01 audit).
      host = "0.0.0.0";
    }
  );

  prepareScript = ''
    set -euo pipefail

    if [ ! -e /dev/pmem0 ]; then
      echo "no /dev/pmem0: nothing to prepare (is the Optane DIMM present?)"
      exit 0
    fi

    # The mode probe must come BEFORE trusting an existing filesystem: with
    # formatOptane=true a non-fsdx namespace has to be recreated even when it
    # happens to carry an xfs.  `ndctl list -n <ns>` prints JSON by default on
    # ndctl 83 (there is no -j flag - using it made this unit fail on EVERY boot
    # until the mount was made to require it; caught by the 2026-10-01 boot
    # test).  /sys/bus/nd/devices/namespace0.0/mode is NOT a substitute: it reads
    # "memory" for an fsdax namespace.
    mode="$(ndctl list -n namespace0.0 2>/dev/null | ${pkgs.jq}/bin/jq -r 'if type == "array" then (.[0].mode // "") else (.mode // "") end' 2>/dev/null || true)"
    fstype="$(blkid -o value -s TYPE /dev/pmem0 || true)"

    if [ "$mode" = "fsdax" ] && [ "$fstype" = "xfs" ]; then
      echo "/dev/pmem0 already carries fsdax+xfs: nothing to do"
      exit 0
    fi

    if [ "$mode" != "fsdax" ]; then
      if [ "${lib.boolToString cfg.formatOptane}" != "true" ]; then
        echo "namespace0.0 mode is '$mode', not fsdax, and formatOptane is off." >&2
        echo "Recreating it destroys whatever is in that namespace.  If that is intended:" >&2
        echo "  services.tiberius-strata.formatOptane = true;" >&2
        exit 1
      fi
      ndctl destroy-namespace namespace0.0 --force
      ndctl create-namespace --mode=fsdax --align=2m
    fi

    fstype="$(blkid -o value -s TYPE /dev/pmem0 || true)"
    if [ -z "$fstype" ]; then
      if [ "${lib.boolToString cfg.formatOptane}" != "true" ]; then
        echo "/dev/pmem0 has no filesystem and formatOptane is off." >&2
        exit 1
      fi
      mkfs.xfs -f -K -m reflink=0 -d su=2m,sw=1 /dev/pmem0
    elif [ "$fstype" != "xfs" ]; then
      echo "/dev/pmem0 carries a '$fstype' filesystem, not xfs: refusing to format it." >&2
      exit 1
    fi
  '';
in
{
  options.services.tiberius-strata = {
    enable = lib.mkEnableOption "the Strata engine on the Optane PMEM";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.strata-sm75;
      description = "The strata engine package (pkgs/strata-sm75).";
    };

    model = lib.mkOption {
      type = lib.types.enum [
        "coder"
        "iq3-s"
      ];
      default = "coder";
      description = "Which lane to serve.  `coder` is the measured default (2.3x the prefill, higher hits).";
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/optane/strata-data";
      description = "The prepared models: packs/ (with experts.bin), ple/, mtp/.";
    };

    modelsRoot = lib.mkOption {
      type = lib.types.str;
      default = "/data/strata-models";
      description = ''
        Root of the raw shard directories.  Each lane's directory holds shard 1
        ONLY: the engine collects every `*-0000N-of-0000M.gguf` beside --native
        and would reject shard 2 as a duplicate split once the PLE shard is
        added.
      '';
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/persist/strata";
      description = "Engine log directory (persistent).";
    };

    context = lib.mkOption {
      type = lib.types.int;
      default = lane.defaultContext;
      description = ''
        Maximum context in tokens.  Measured on the Coder: 131K gives ~35 tok/s
        decode / ~410 tok/s prefill at 94% hit; 262K gives ~29 / ~384 at 92%.
      '';
    };

    kv = lib.mkOption {
      type = lib.types.enum [
        "int8"
        "q4_0"
        "k8v4"
      ];
      default = "k8v4";
      description = "KV cache format.  K8V4 gives the 262K window at ~5.2 GB of VRAM.";
    };

    hostTierMib = lib.mkOption {
      type = lib.types.int;
      default = 1024;
      description = ''
        MiB of the hottest profile-ranked experts the GPU cache does not hold
        kept in ordinary RAM (the host expert tier).  Measured ~8% off the CPU
        pool at 1024; 0 disables it and restores the pure mmap path.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
    };

    mountOptane = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Declare the /optane XFS(dax=always) mount and its prepare unit.";
    };

    formatOptane = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Allow the prepare unit to destroy+recreate the namespace and mkfs the
        device.  DESTRUCTIVE; only set this when the Optane is to be dedicated
        to Strata and its current contents do not matter.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      cfg.package
      pkgs.libndctl
    ];

    # Belt-and-braces against the lockout class this module already caused once
    # (2026-10-01): an ordering cycle made systemd drop systemd-tmpfiles-setup,
    # /var/empty never appeared and sshd refused to start, so the box booted with
    # tailscaled alive and nothing else.  sshd now makes its own privilege
    # separation directory, so it starts even if tmpfiles is skipped.
    systemd.services.sshd.serviceConfig.ExecStartPre = [
      "+${pkgs.coreutils}/bin/mkdir -p /var/empty"
    ];

    fileSystems."/optane" = lib.mkIf cfg.mountOptane {
      device = "/dev/pmem0";
      fsType = "xfs";
      options = [
        "dax=always"
        "noatime"
        # nofail: a bad namespace/fs must not fail local-fs.target and risk the
        # boot; the strata service then simply does not start (sshd still does).
        # The prepare unit is pulled in by Wants+Before only, NOT
        # x-systemd.requires: a bug in that script must not turn into "no
        # /optane, no service" (exactly what happened on the 2026-10-01 boot) -
        # the mount is harmless to attempt, and the prepare's destructive path
        # stays gated by formatOptane.
        "nofail"
        "x-systemd.device-timeout=30"
      ];
      noCheck = true;
    };

    # server.py appends to the engine log forever; the box runs months between
    # reboots and the log already holds several startup sequences.
    services.logrotate.settings.strata = {
      files = "${cfg.stateDir}/strata-*.log";
      size = "256M";
      rotate = 4;
      missingok = true;
      copytruncate = true;
    };

    systemd.services.strata-optane-prepare = lib.mkIf cfg.mountOptane {
      description = "Prepare the Optane PMEM fsdax namespace and XFS (idempotent)";
      # Pulled in by the mount and ordered before it.  DefaultDependencies=false
      # is REQUIRED: the default implicit After=basic.target closes an ordering
      # cycle (basic -> sysinit -> local-fs -> optane.mount -> this unit -> basic)
      # and systemd breaks it by dropping the systemd-tmpfiles-setup job, leaving
      # /var/empty missing and taking sshd down with it (measured on the gen-41
      # boot, 2026-10-01).  The After on the device node keeps the prepare script
      # from no-oping on a not-yet-created /dev/pmem0.
      wantedBy = [ "optane.mount" ];
      before = [ "optane.mount" ];
      after = [ "dev-pmem0.device" ];
      unitConfig.DefaultDependencies = false;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = with pkgs; [
        libndctl
        xfsprogs
        util-linux
        jq
        coreutils
      ];
      script = prepareScript;
    };

    systemd.services.tiberius-strata = {
      description = "Strata ${cfg.model} (Qwen3.8-Flash-Next) on the RTX 2080 Ti / Optane";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [
        "network-online.target"
        "nvidia-persistenced.service"
      ];
      # One GPU: never resident beside the vLLM lanes.
      conflicts = [
        "tiberius-qwen38.service"
        "tiberius-qwen38-uncensored.service"
        "tiberius-ninfer.service"
      ];
      unitConfig.RequiresMountsFor = [ cfg.dataDir cfg.modelsRoot ];
      environment.LD_LIBRARY_PATH = "${config.hardware.nvidia.package}/lib";
      serviceConfig = {
        Type = "exec";
        LimitMEMLOCK = "infinity";
        # Restart=on-failure + 10s backoff alone defeats systemd's default start
        # limit, so a permanently broken start (missing pack, empty /optane, bad
        # profile) loops forever in "activating (auto-restart)" and never shows
        # in systemctl --failed.  Bound it so the failure is visible.
        Restart = "on-failure";
        RestartSec = "10s";
        StartLimitIntervalSec = 300;
        StartLimitBurst = 3;
        ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p ${cfg.stateDir}";
        ExecStart = lib.escapeShellArgs [
          "${python}/bin/python3"
          "${cfg.package}/share/strata/serve/server.py"
          "--engine"
          "strata"
          "--config"
          (toString strataJson)
          "--port"
          (toString cfg.port)
        ];
      };
    };
  };
}
