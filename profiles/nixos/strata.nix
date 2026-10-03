{
  config,
  lib,
  pkgs,
  ...
}:

# Strata (Qwen3.8-Flash-Next) on the Optane PMEM, two model lanes.  Measured
# 2026-10-03 on the deployed v0.1.38 stack (same harness, 131072 context, fresh
# engine per cell, cold cache, /data/coderlane):
#
#   * `coder`  -- the Coder IQ1_M release: half the experts (12,288), coding/
#                 tool/vision-pruned, 23.4 GiB pack.  790.7 tok/s prefill at
#                 4344 tokens and 1129.9 at 27575; 39.6 / 34.3 tok/s decode at
#                 94.1 / 91.3% VRAM expert hit; the 6 GiB DAX window covers layers
#                 0..12, so a prompt needs only 4 rotations.  That is 1.73x /
#                 1.12x the prefill and 1.66x / 1.63x the decode of iq3-s at the
#                 same window - the prefill lead collapses with length because
#                 this lane stops being byte-bound (its read is attention/GDN/
#                 dense GEMM).  The quality trade is documented upstream: 91.3%
#                 of the full model's SWE-bench Verified, weaker outside code
#                 including CJK (#438) - use iq3-s for prose.
#   * `iq3-s`  -- the original IQ3_S (24,576 experts, "matches the full model"),
#                 46.8 GiB pack.  456.6 tok/s prefill at 4344 tokens / 1004.5 at
#                 27575 with 23.9 / 21.0 tok/s decode at 131072 (82.6 / 81.8%
#                 hit); the deployed 262144 reads 457.0 / 996.8 tok/s and decodes
#                 ~20 tok/s at 77% hit, each extra 64K of window costing ~414
#                 cache slots.  Prefill is bounded by the non-resident expert
#                 bytes per chunk, paced by the Optane's ~6.8 GB/s.
#
# The engine is built for sm_75 by pkgs/strata-sm75 (with the local engine patch:
# the sliding DAX window, the FP16 dense GEMMs and the registered decode refill);
# the model itself is NOT in the store -- it was prepared once on the host by the
# setup flow's iq_pack step and lives on the DAX-mounted Optane.  This module wires up:
#
#   * the fsdax namespace + XFS(dax=always) mount (idempotent prepare unit),
#   * the OpenAI/Anthropic server over serve/server.py with the measured flags
#     (mmap experts from the Optane, the KV the host selects - `k8v4` by
#     default, `int8` on tiberius - MTP4 + suffix drafts, the
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
    # psutil (the engine-supervision/telemetry path), and jsonschema lazily for
    # response_format json_schema (serve/structured.py -- without it the server
    # only checks that the answer is one JSON object and says so once).
    ps.jinja2
    ps.pillow
    ps.psutil
    ps.jsonschema
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

  # v0.1.38's gguf_split_paths() THROWS when a "--native ...-0000N-of-0000M.gguf"
  # has a missing sibling shard (0.1.29's model_shards() silently skipped absent
  # shards), and the GGUF reader additionally validates the file's own split
  # metadata - a shard-1 file handed over as a whole model is refused with "is
  # shard 1 of 2, but it was opened as a whole model".  The deployed lanes
  # deliberately keep shard 1 only under modelsRoot (shard 2 lives under
  # dataDir/ple), so the service assembles a per-lane directory holding BOTH
  # shards as symlinks under their real split names and points --native and
  # --ple-gguf INSIDE that one directory: naming the same derived string twice is
  # what keeps the engine from appending the PLE shard a second time
  # (native_dense.cpp rejects a repeated split number, and a different spelling of
  # the same file is exactly that bug).  ExecStartPre remakes the links on every
  # start; stateDir survives reboots, and ln -sfn is idempotent.
  nativeDir = "${cfg.stateDir}/native/${lane.pack}";
  # v0.1.38's gguf_split_paths() derives the sibling shard's name from --native's
  # own "-00001-of-00002" suffix and demands it beside it, so the shared PLE table
  # must be linked under THAT name.  A hardcoded IQ3_S name only satisfies the
  # iq3-s lane: `model = "coder"` then dies at startup with "missing model shard
  # ...IQ1_M-00002-of-00002.gguf (shard 2 of 2)" (reproduced 2026-10-03).  Bumping
  # the split number in lane.shard1 reproduces the engine's derivation for every
  # lane; for iq3-s it yields exactly the name this used to hardcode.
  pleShard = lib.replaceStrings [ "-00001-of-" ] [ "-00002-of-" ] lane.shard1;
  # The file on disk is one shared table (the Coder release ships no shard 2 of
  # its own), linked per lane under the derived name above.
  pleFile = "Qwen3.8-Flash-Next-GSQ-RCO-IQ3_S-00002-of-00002.gguf";

  strataJson = pkgs.writeText "strata-${cfg.model}.json" (
    builtins.toJSON {
      exe = "${cfg.package}/bin/strata";
      args = [
        "--pack"
        "${cfg.dataDir}/packs/${lane.pack}"
        "--native"
        "${nativeDir}/${lane.shard1}"
        "--ple-gguf"
        # Shared by both lanes on purpose: the PLE table (shard 2) is common to
        # the IQ3_S and Coder releases, and the coder has no shard 2 of its own
        # (verified 2026-09-30 on the box: /optane/strata-data/ple/ holds only
        # this file and the coder's models dir holds only its shard 1).  The
        # engine appends this shard to the dense tensors, which both lanes rely
        # on.  It is fed
        # from nativeDir so the path string equals the one the engine derives
        # from --native's split name (see nativeDir above; the per-lane name is
        # derived in pleShard, and the coder lane measured 1,129.9 tok/s prefill
        # at 27575 tokens on 2026-10-03).
        "${nativeDir}/${pleShard}"
        "--ple-io"
        "mmap"
        "--expert-profile"
        "${cfg.package}/share/strata/data/${lane.profile}"
        "--expert-cache"
        "auto"
        "--prefill"
        # v0.1.38's prompt path streams, per chunk, the union of the experts that
        # chunk's tokens route to, and above ~2K tokens that union is nearly the
        # whole pack, so the DMA per token falls as the chunk grows.  The engine
        # ACCEPTS a fixed chunk by halving it (`for (c = chunk; c >= 256; c /= 2)`
        # in generate.cpp) and takes the first value that fits the prompt borrow,
        # so a request only ever lands on a halving of what you ask for.
        # Measured 2026-10-03 on the served config (262144, kv=int8, 6288 slots,
        # borrow <= ~6160, /data/chunkint8): asking 28672 is halved to 14336 and
        # reads a 27575-token prompt in 30.7 s (898 tok/s); asking 28160 is
        # accepted AS-IS and reads it in 26.8 s (1029 tok/s, +14.6%, -21.6% expert
        # bytes) with 6109 slots borrowed (51 spare; PR #547 makes that 5554
        # borrowed and 734 spare, and takes 1.8-2.6% off this read), while the 4.3K
        # prompt and the decode after are unchanged.  The boundary is reproduced
        # with second engines (28416 halves to 14208, -0.9%); 27648 is the same
        # speed with 3x the headroom if another tenant ever shrinks the cache.
        # History: on the older k8v4 config (6657 slots, borrow 6223) 28672 was the
        # largest accepted value, giving 992 tok/s at 27.5K and 928 at 110K where
        # the old auto/8192 gave 622.  The cap moves with the expert cache, so
        # re-measure it whenever the KV or context changes - and read the engine's
        # own `prompt chunk X -> Y` line rather than assuming the value you asked
        # for is the value in force.
        "28160"
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
      ]
      # v0.1.38 has the resident host tier natively: --resident-budget-gib N keeps
      # the N GiB of the GPU cache's complement that the expert profile ranks
      # hottest, and implies --mmap-experts + --resident-cpu-experts (the parser
      # treats them as one mode).  The unit is GiB, so the old --resident-cpu-mib
      # 1024 is exactly 1.0 here; 0 keeps the plain mmap path instead, because the
      # flag itself requires N > 0.  The old --resident-cpu-mib and its relaxed
      # --adapt-every requirement are gone: upstream admits the tier beside the
      # adaptive cache (reserve_exchanges) by itself.
      ++ lib.optionals (cfg.hostTierGib > 0) [
        "--resident-budget-gib"
        (toString cfg.hostTierGib)
      ]
      ++ lib.optionals (cfg.hostTierGib <= 0) [
        "--mmap-experts"
      ]
      ++ [
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
        # tiberius: the engine's conversation cache is left at its defaults
        # (--prompt-cache 6, --prompt-cache-every 16384, --prompt-cache-root
        # 2048).  Measured 2026-10-02: resume is pure token-prefix matching, an
        # append-only conversation pays ~4.2 s of prefill per turn flat in
        # conversation length (the previous reply is reused for free), an exact
        # repeat pays 154 ms against 6,239 ms, and a shared system block smaller
        # than the 2048-token root gets no root checkpoint at all (1K block:
        # 0/4 requests reused; 2K/4K: 91-95%).
        #
        # The 2048 default sits at the measured break-even: creating a root costs
        # one extra batched pass (+3.4 s on the first request of a chat, and
        # ~118 MB of host RAM per pinned checkpoint, independent of its length),
        # while each reuse saves ~1.6 ms per root token - break-even after
        # F/(m*r) = 2063/r reuses (2048 -> 1, 1024 -> 2, 512 -> 4).  Lowering the
        # root to 512 wins ~6-10% of prompt-read time only for traffic with a
        # stable sub-2K system block reused >=4x, and changes nothing for a >=2K
        # block; 1024 is only better if 512-1K blocks should NOT be rooted.
        #
        # The chat template puts the tools JSON and any reasoning instruction at
        # the FRONT of the prefix, so changing either invalidates every cache.
        #
        # Re-measured 2026-10-03 on the served stack (int8/262144/28160, fresh
        # private engines; /data/serving3): the pin condition is the prompt's
        # FIRST TURN BOUNDARY at index >= 2048, not the block's own token count,
        # so budget a shared block of >= ~2100 tokens AS RENDERED - a 2052-token
        # standalone system message lands at 2045 and pins nothing (three chats:
        # 0/0/0% reuse, and every zero-reuse request clears the whole chain);
        # boundaries of 2053/2992 reuse 91.1%/93.7% for later chats.  Only the
        # ROOT is pinned - the other 5 of --prompt-cache 6 rotate LRU, so a
        # chat's own continuation falls back to the root (83.1% here) after
        # other chats.  Exact repeats are 193-264 ms; append-only turns hold
        # 4.9-6.4 s flat 8K -> 60K, fresh = the appended turn (~350) + the
        # previous reply (128) when its re-tokenization does not byte-match,
        # + ~9 turn-header tokens.  --short-read 64 applies to the engine's
        # FRESH READ, so client text must be <= ~55 tokens for the verify path;
        # the verify/batched cost cross-over is ~90-100 fresh tokens (~34-70
        # ms/token against a ~3.2-3.7 s floor + ~5-8 ms/token).  The borrow is
        # 6109 of 6288 slots - 5554 (88.3%) with PR #547 carried - and costs the
        # next request nothing measurable; cold start is 18-26 s (not ~50 s) and
        # a restart still loses the chain (conversation-cache-mib stays 0: no
        # parked caching).
        # Client note: pi's and omp's byte-stable boundaries measure ~1.95-2.0k
        # tokens as rendered, i.e. under the root - they pin nothing today;
        # --prompt-cache-root 1024 would pin them at the documented 2-reuse
        # break-even above (not taken).
        "--stats"
      ];
      cwd = "${cfg.package}/share/strata";
      tokenizer = "${cfg.dataDir}/packs/${lane.pack}/tokenizer";
      model_name = lane.modelName;
      log = "${cfg.stateDir}/strata-${cfg.model}.log";
      lib_dirs = [ "${config.hardware.nvidia.package}/lib" ];
      env = {
        STRATA_SPLIT_TIMING = "1";
        # v0.1.38's --resident-budget-gib page-locks its copy by default
        # (cudaHostAlloc / cudaHostRegister, reported as "mapped pinned").  The
        # measured tier on this box is the PAGEABLE one (the deployed log reads
        # "resident 1.00 GiB, pinned 0.00 GiB"), and 1 GiB of pinned host memory
        # would also sit on the ~7 GiB per-process cudaHostRegister cap that the
        # sliding DAX window already probes at ~6.2 GiB.  STRATA_RESIDENT_PIN=0 is
        # upstream's own "the --resident-cpu-experts form" arm.
        STRATA_RESIDENT_PIN = "0";
        # The budget path clamps to (available RAM - this headroom - 256 MiB).
        # The default headroom is 4 GiB, which exceeds what this 7.4 GiB box has
        # available at engine start (~2 GiB) and would silently zero the tier;
        # the old --resident-cpu-mib path had no clamp at all.  0 keeps 1 GiB
        # (only the 256 MiB margin applies).
        STRATA_RESIDENT_HEADROOM_GIB = "0";
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
        # tiberius: the decode-time VRAM refill reads from registered (pinned)
        # sources instead of the pageable bounce path.  98% of its 2 MiB copies
        # were pageable at ~0.87 ms/copy (2.3 GB/s) and sat on the decode loop's
        # critical path (issue 19.9 + join 18.0 ms of a 122 ms window; the
        # adaptive tier is what keeps the cache hit rate at 80% instead of the
        # static profile's 68%).  The flag registers each batch's pageable source
        # spans just before its copy, MERGING them into disjoint runs first (an
        # H2D copy whose source begins inside a registration and ends outside it
        # is refused by the driver - that is the "adaptive refill failed" 400 an
        # unmerged version produced on every second request), and releases them
        # only once the batch's event has completed.  Measured 2026-10-02 on the
        # real corpus, counterbalanced, 8 runs/arm, fresh engine per run: decode
        # 19.61 -> 22.00 tok/s on a 4292-token prompt (+12.2%), 26.73 -> 28.61 on
        # 3514 (+7.1%), 21.82 -> 23.11 on 3456 (+5.9%); refill join 18.04 ->
        # 1.46 ms/window, issue 19.88 -> 3.12, pageable copy 0.866 -> 0.003 ms;
        # expert-cache hit rate and prefill unchanged, warm-up state hash
        # bit-identical, peak registered ~6292 MiB against the driver's ~7 GiB
        # process cap with 0 refusals in 64 measured requests.
        STRATA_REFILL_PIN_SRC = "1";
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
      # v0.1.38's serve layer checks the Host header on every request (the
      # DNS-rebinding fix, server.py parse_request): it answers to localhost and
      # *.localhost, IP literals, the bind address and - because it listens
      # beyond loopback - this PC's own hostname and hostname.local, and 403s
      # anything else.  Verified on the deployed service: 127.0.0.1, localhost,
      # 192.168.1.3, the tailnet IP, `tiberius` and `tiberius.local` are 200;
      # the MagicDNS FQDN needs this list.  NOTE this key is read by the SERVER
      # from the config JSON - the env dict above only reaches the engine, so
      # STRATA_ALLOWED_HOSTS there does nothing (measured: the server logged no
      # "also answers to" line and 403'd the FQDN).
      allowed_hosts = [ "tiberius.tail01b8d.ts.net" ];
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
      default = "iq3-s";
      description = ''
        Which lane to serve.  `iq3-s` is the quality lane and the default: the
        original IQ3_S pack (24,576 experts, "matches the full model") and the
        one the box serves.  `coder` is the low-footprint alternative (IQ1_M,
        half the experts, 23.4 GiB pack); measured 2026-10-03 at 131072 context
        it does 1.73x / 1.12x the prefill and 1.66x / 1.63x the decode of iq3-s
        (790.7 / 1129.9 tok/s prefill, 39.6 / 34.3 tok/s decode at 4344 / 27575
        tokens at 94.1 / 91.3% hit), at the cost of the documented quality trade
        (91.3% of the full model's SWE-bench Verified, weaker outside code
        including CJK).  Not taken here on purpose.
      '';
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
        ONLY, under its own `-00001-of-00002.gguf` name; the service symlinks it
        (and the shared PLE shard) into stateDir/native/<lane>/ on every start,
        because v0.1.38's gguf_split_paths() makes a missing sibling shard fatal
        and refuses a shard file opened as a whole model.  Shard 2 is fed in
        through --ple-gguf from that same directory, so the engine's shard list
        names it exactly once.
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
        Maximum context in tokens.  Measured on the Coder (2026-10-03, 131072,
        fresh engine, cold cache): 790.7 / 1129.9 tok/s prefill and 39.6 / 34.3
        tok/s decode at 4344 / 27575 tokens (94.1 / 91.3% hit).  On iq3-s
        (2026-10-03, k8v4, fresh engine per cell): prefill is
        ~flat in prompt length (644-706 tok/s from 14K to 110K tokens), 131K
        decodes ~21 tok/s at 81% hit and 262K ~18 tok/s at 78%, and each extra
        131K of window costs ~830 expert-cache slots.  Above 262K the model is
        past its trained window (the engine runs --rope-scaling none) and the
        cache thrashes: 524K -> 14.5 tok/s / 70% hit, 786K -> 10.6 / 54%.
      '';
    };

    kv = lib.mkOption {
      type = lib.types.enum [
        "fp16"
        "int8"
        "q4_0"
        "k8v4"
      ];
      default = "k8v4";
      description = ''
        KV cache format, cheapest precision to highest, all measured 2026-10-03
        (source cell sizes in kv_q4.hpp / kv_q8.hpp / layer.cpp; envelopes and
        perf on this box, 256 gen): q4_0 576 B/cell (both rotated Q4_0 - worth it
        only under VRAM pressure); k8v4 816 B/cell (K INT8 + V rotated Q4_0, the
        module default: 6657 slots at 262144, decode 21.4/22.4 tok/s at 4344/
        27575 tokens); int8 1056 B/cell (K and V both INT8 with FP16 scales: 6288
        slots, decode 20.3/20.7); fp16 2048 B/cell (the ceiling: 4607 slots at
        262144, decode ~15.8-16.4 = -22..-24% vs int8, hit -9 pts, the loss being
        purely the smaller expert cache - but at 131072 it keeps the full 28672
        chunk with 6464 slots and costs nothing: 994 tok/s prefill, 18.4 tok/s
        decode, 77% hit).  Every mode also shrinks the prompt chunk the engine can
        borrow for: int8 and fp16 land on 14336 at 262144 (which is why --prefill
        asks 28160, the largest value accepted without halving).
      '';
    };

    hostTierGib = lib.mkOption {
      type = lib.types.float;
      default = 1.0;
      description = ''
        GiB of the hottest profile-ranked experts the GPU cache does not hold kept
        in ordinary RAM (upstream v0.1.38's --resident-budget-gib, a float so a lane
        can ask for e.g. 0.5).  1.0 is the measured setting (the old
        --resident-cpu-mib 1024, ~8% off the CPU pool); 0 keeps the pure mmap path.
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
        ExecStartPre = [
          "${pkgs.coreutils}/bin/mkdir -p ${cfg.stateDir}"
          # v0.1.38's gguf_split_paths() demands every shard named by --native's
          # "-of-NNNNN" suffix beside it, and it validates the GGUF's own split
          # metadata too, so shard 1 cannot be passed alone or under a made-up
          # name.  nativeDir is therefore assembled here with BOTH shards as
          # symlinks under their real split names; --native and --ple-gguf then
          # point inside it.  ln -sfn is idempotent and replaces a stale link.
          "${pkgs.coreutils}/bin/mkdir -p ${nativeDir}"
          "${pkgs.coreutils}/bin/ln -sfn ${cfg.modelsRoot}/${lane.models}/${lane.shard1} ${nativeDir}/${lane.shard1}"
          "${pkgs.coreutils}/bin/ln -sfn ${cfg.dataDir}/ple/${pleFile} ${nativeDir}/${pleShard}"
        ];
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
