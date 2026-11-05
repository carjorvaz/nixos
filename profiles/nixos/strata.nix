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
# The engine is built for sm_75 by pkgs/strata-sm75 (local patches: the sliding
# DAX window, the registered decode refill, and the VBMI-free AVX-512 expert
# tier).  The 0.1.45 Turing kernel series is enabled (STRATA_SM75_PERF=1; it is
# bitwise on the measured cells - see docs/VALIDATION.md).  The dense FP16
# tensor-core GEMMs are upstream's own bf16_path() now (STRATA_BF16_TC=1).
# The model itself is NOT in the store -- it was prepared once on the host by the
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

  # The engine only ever listens here.  The two doorways clients use - 8080
  # (interactive) and 8090 (background) - belong to the lease proxy below,
  # which is what keeps a background request from evicting the interactive
  # conversation.  Loopback only, so nothing reaches the engine around it.
  upstreamPort = 8081;

  # The lease front end (pkgs/strata-lease-proxy.py carries the design notes):
  # a store path, so there is no copy under /persist to keep in sync.
  leaseProxy = pkgs.writeText "strata-lease-proxy.py" (
    builtins.readFile ../../pkgs/strata-lease-proxy.py
  );

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

  # upstream's gguf_split_paths() THROWS when a "--native ...-0000N-of-0000M.gguf"
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
  # upstream's gguf_split_paths() derives the sibling shard's name from --native's
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
        # pmem park tier (validated 2026-11-05): when the RAM park pre-check
        # refuses, the conversation is written as a v1 session file on the
        # Optane and the next turn restores it with the streamed reader.
        # Measured: 4.5 s / 3.6 GB capture per 250k park, 5.15 s restore
        # (225,280-token stable checkpoint), answer shas identical; the RAM
        # path is unchanged.  Costs: a blocking capture on the request thread
        # and Optane write volume/thermal headroom - the telemetry module
        # watches this lane; disable by dropping these four flags.
        "--conversation-park-dir"
        "${cfg.dataDir}/parks"
        "--conversation-park-mib"
        "6144"
        "--conversation-park-slots"
        "4"
        "--conversation-park-min-free-mib"
        "4096"
        "--prefill"
        # Upstream's prompt path streams, per chunk, the union of the experts that
        # chunk's tokens route to, and above ~2K tokens that union is nearly the
        # whole pack, so the DMA per token falls as the chunk grows.  The engine
        # ACCEPTS a fixed chunk by halving it (`for (c = chunk; c >= 256; c /= 2)`
        # in generate.cpp) and takes the first value that fits the prompt borrow,
        # so a request only ever lands on a halving of what you ask for.
        # v0.1.39 rewrote the streamed ring's sizing (#583, STRATA_RING_BYTES) and
        # the carried #1283 accounting moved the boundary: re-measured 2026-10-08
        # at v0.1.40.2 (same 262144/int8/6288-slot config, /data/chunkint8
        # summary-1402.txt, STRATA_UNBUFFERED_LOAD=0 in force - without it, see the
        # file-tier note above, every cell reads 2x slower):
        #   * 28160 is accepted AS-IS and reads the 27575-token prompt in 23823 ms
        #     (1157.9 tok/s, 3 runs 23684/23894/23823) with the routed-only staging
        #     override retired; that override (STRATA_PREFILL_RING=8) cost 10.3%:
        #     26282 ms (1049.5 tok/s, 5 runs) with it in force, and the borrow rises
        #     5553 -> 6036 slots without it (6109 at v0.1.38).  Re-measured
        #     2026-10-08 on this config (262144, int8, page-cache tier, fresh engine
        #     per cell, /data/chunkint8/summary-1402.txt).
        #   * 28672 NO LONGER halves (borrow 5649, 10.70 GiB) - it is no longer the
        #     slower arm it was at 0.1.38, but it was only measured unbuffered, so
        #     it has no page-cache number yet.
        #   * auto stays the #669 arm and is worse: 8192-token chunks, a 8-slot
        #     ring, 42.9 s (642.6 tok/s) with the page cache.
        #   * the context trade (128 gen): 131072 decodes 21.6 tok/s at a 80.9% hit
        #     against 18.0 tok/s at 76.6% for the deployed 262144 window (26228 vs
        #     26616 ms read).
        # The boundary moves with the expert cache and the borrow accounting, so
        # re-measure it whenever the KV, context or engine changes - and read the
        # engine's own `prompt chunk X -> Y` line rather than assuming the value you
        # asked for is the value in force.  Re-screened 2026-11-04 on the current
        # 0.1.56/DFlash2 stack (fresh engine per arm, P1/P2/P27): 16384 costs
        # +2.9/+3.3/+10.3% read, 8192 costs +1.5/+4.9/+56.3%, and reserving the prompt
        # buffers (--no-prefill-borrow) frees no intercept while collapsing the expert
        # cache 7,859 -> 4,959 slots (-37%, P27 read +52%); 28160 with the borrow stays.
        # A fresh-prompt sweep puts the fixed cost at ~5.1 s + 0.60 ms/token
        # (1,672 tok/s), and STRATA_PREFILL_TIMING attributes 37% of a 4.2k prompt's
        # GPU timeline to `wait copy` (the DAX pack stream), so the remaining win is
        # rotation/copy overlap, not a chunk flag.  Evidence:
        # docs/exec-plans/active/strata-tuning-next.md "Round 2 campaign results".
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
        # --kv-grow: the K/V takes VRAM only for the cells the requests reach
        # (16,384 of 262,144 mapped at start, 0.25 of 3.35 GiB) and the expert
        # cache lends the rest, giving slots back as the context grows.  Measured
        # 2026-11-01, fresh engine, lambda 1.2, same cells as the control:
        # 7,766 expert slots against 6,123 (+27%), 4,252-token read 457.7 ->
        # 497.8 tok/s (+8.8%) and decode 49.2 -> 57.3 (+16.5%), 3,477-token
        # 384.3/51.6 -> 408.4/64.5, 26,134-token read 1,162.3 -> 1,245.5 (+7.2%)
        # at a 99.1% hit.  It is refused when --resident-budget-gib is present
        # (that flag sets resident_cpu_experts, which the kv-grow gate excludes),
        # which is why hostTierGib below now defaults to 0.
        "--kv-grow"
        # Parked conversations: the only mechanism that keeps a conversation's
        # prefix while another client's uncached request runs in between.  The
        # engine parks the conversation's recurrent state AND its K/V image in
        # host RAM (the elastic K/V above is what keeps the image restorable) and
        # restores it by token identity, never another conversation's bytes.
        # Measured 2026-11-01, one 2.4k conversation around a 19.4k foreign
        # request: with parking off, turn 2 reused 0 of 2,443 tokens and re-read
        # 9,325 ms; with these flags, 2,392 reused and 1,238 ms.  384 MiB is the
        # RAM floor: the 2,560 default refuses on this box ("need 373 MiB plus
        # 2560 MiB floor, 1466 MiB available") and even 512 skipped while a
        # request held RAM ("need 728 MiB plus 384 MiB floor, 802 MiB
        # available").  4 slots, not 2: on the live service a third conversation
        # (a hindsight job beside ours and a probe's foreign prompt) evicted the
        # oldest - ours - one park after it was written, so the cap must cover
        # ours plus whatever background traffic interleaves.  The 1,536-token
        # floor keeps short side requests from taking a slot, and park-gain 512
        # avoids writing a whole snapshot for a turn that grew a few hundred
        # tokens.  Under real RAM pressure a background conversation that is
        # itself refused on the floor can still overwrite ours (measured: one of
        # three live probes lost the prefix, two kept it), so this is best-effort
        # isolation, not a guarantee.
        "--conversation-cache-mib"
        "2048"
        "--conversation-cache-slots"
        "4"
        "--conversation-cache-min-tokens"
        "1536"
        "--conversation-cache-min-free-mib"
        "384"
        "--conversation-cache-park-gain"
        "512"
      ]
      # upstream has the resident host tier natively (0.1.35+): --resident-budget-gib N keeps
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
      # 5554 of 6288 slots (88.3%; 6109 before PR #547) and costs the
      # next request nothing measurable; cold start is 18-26 s (not ~50 s) and
      # a restart still loses the chain (conversation-cache-mib stays 0: no
      # parked caching).
      # Client note: pi's and omp's byte-stable boundaries measure ~1.95-2.0k
      # tokens as rendered, i.e. under the root - they pin nothing today;
      # --prompt-cache-root 1024 would pin them at the documented 2-reuse
      # break-even above (not taken).
      #
      # No --stats here: in --serve mode the engine returns before its stats
      # printer runs, so the flag is dead in this config; the per-request
      # figures come from serve's own stderr lines and STRATA_SPLIT_TIMING=1.
      ;
      # 0.2.10's serve layer runs vram_fit.fit_start on every engine start; on
      # CUDA its only knob is --kv-resident.  Its estimate does not model
      # --kv-grow, so the first 0.1.56 start (2026-11-03) declared this card
      # short and injected `--kv-resident 4096`: --kv-grow is off whenever a KV
      # window is set, and the DAX window fell from 5.52 to 2.70 GiB.
      # `--kv-resident 0` is the engine's unset value (kv_grow stays allowed),
      # and as a user_arg it makes fit_start's kv_fixed skip the knob.
      # Screened on the same stack 2026-11-04 and NOT carried: --spec 8 (-2.9% L-live
      # decode: more tokens/verify-window but slower windows), --lookup-max-t 8 (a
      # no-op - the verify window stays 8) and 12 (-1.4%), finer --draft-conf, and
      # --draft-cap (the serve layer strips it; the cap follows --spec).  k8v4 on the
      # 26k long-context cell was +2.6% decode (below the 3% gate), -10.7% on L-live,
      # +10.5% P27 read, with answers drifting, so int8 stays.  Model-card sampling
      # beat card0 (presence_penalty 0) 58.67 vs 58.00 over 3 eval80 passes; keep the
      # card.  Evidence: docs/exec-plans/active/strata-tuning-next.md results section.
      user_args = [
        "--kv-resident"
        "0"
      ];
      cwd = "${cfg.package}/share/strata";
      tokenizer = "${cfg.dataDir}/packs/${lane.pack}/tokenizer";
      model_name = lane.modelName;
      # DFlash2 is the drafter on this card (measured 2026-11-04): engine 0.1.56
      # runs it on sm_75, where upstream's table says "untested".  The pack was
      # converted here from the pinned source (incoai/Qwen3.8-Flash-Next-DFlash2
      # revision a22a1744; Q4_0 pack sha cda40d62..., selector pack
      # 4a42b98...) and lives in ${cfg.dataDir}/dflash2 beside draft_vocab.bin,
      # the English subset.  Against the MTP, 3+3 counterbalanced: prompts flat
      # (-1.3% / -0.1% at 3.5K / 26K, +0.3% at 4.2K), decode +4.8% / +4.7% /
      # +3.9%, expert cache 7,859 vs 7,762 slots, eval80 58/80 vs 59/80 (the
      # set's noise).  DFlash2 serves one request at a time (no --batch, which
      # this lane does not use); a missing pack falls back to the MTP with a
      # line in the log.
      drafting = "dflash2";
      # The served default is the model card's sampling (owner decision,
      # 2026-11-04): a request that names no sampling gets Qwen3.8's card
      # values - non-thinking 0.7 / top_p 0.8 / top_k 20 / presence_penalty 1.5,
      # thinking 1.0 / 0.95 / 20 - as upstream's serve layer implements them
      # (`MODEL_CARD_SAMPLING`, and the family defaults to qwen4exp when the
      # config names none).  The old pin here was temperature 0, which made the
      # lane greedy; measured 2026-11-04 (eval80, one fit-pinned DFlash2 start,
      # request sampling overrides): greedy+penalty 58/80, pure greedy 60, card
      # 59, card without penalty 63 - all inside the set's binomial noise
      # (1 sigma about 5.4), and the repetition probe showed no cost.  A client
      # that sends sampling keys still wins; campaigns that need determinism
      # send temperature 0 per request.
      log = "${cfg.stateDir}/strata-${cfg.model}.log";
      lib_dirs = [ "${config.hardware.nvidia.package}/lib" ];
      env = {
        STRATA_SPLIT_TIMING = "1";
        # 0.2.7's residency-biased router (upstream's STRATA_ROUTE_PRIOR): after
        # the router, the top-k is picked again with a logit bonus for experts
        # already on the card, which trades a little routing fidelity for far
        # fewer Optane reads.  Upstream shipped it on by default for 12 GB cards
        # in 0.2.7 and turned that default OFF again in 0.2.8, tying it to
        # repeated text in long sessions; this box keeps it explicitly, at 1.2
        # rather than the shipped 1.5, because the degeneration reproduces at 1.5
        # here and not at 1.2.  All measured 2026-10-30 on the v0.2.8 engine:
        #   * speed, fresh engine, greedy: decode 22.4 -> 54-56 tok/s on the
        #     4,252-token cell (expert-cache hit 77.8 -> 98.0%), 26.8 -> 61.4 on
        #     3,477, 29.6 -> 78 on 26,134; prompt reads unchanged (466 / 1,155
        #     tok/s).  lambda 1.2 costs ~6% of that (the 80-task set runs in
        #     53.3 s against 50.3 s) and is still ~2.3x the un-routed lane.
        #   * quality, 80 exact-answer tasks (arithmetic, units, logic, Python
        #     output, structured data): 61/80 off, 60/80 at 1.2, 56 and 58 in two
        #     runs at 1.5 (sigma ~3.8, so 1.2 is indistinguishable from off).
        #   * long sessions, a 9-turn continuation probe, two runs per arm: off
        #     no identical turn, 1.2 none in either run, 1.5 one run clean and one
        #     with FIVE identical 301-character answers in a row (60.8% cross-turn
        #     8-gram repeats) - the 0.2.8 note's failure mode, reproduced.
        #   * retrieval: a needle at 27.8k tokens, depth 10/50/90, found 3/3 in
        #     both arms; the 26k decode is unchanged by the router.
        # It changes which experts run, so wording differs from the off arm by
        # construction; STRATA_ROUTE_PRIOR=0 (or STRATA_DEFAULTS=026) is the
        # escape hatch.
        STRATA_ROUTE_PRIOR = "1.2";
        # The RTX 20 (sm_75) kernel series, opt-in upstream since 0.1.45
        # because nobody on the team has a Turing card.  It is bitwise on this
        # box: all four ab24 cells (4252 / 19407 / 26134 / 27720-token prompts)
        # returned the same answer sha with the series on and off.  Measured
        # 2026-10-24 on the 0.1.49.2 build, 3 runs with the series against 5
        # controls, counterbalanced (A-B-B-A), medians: prompt read
        # +0.5 / +5.6 / +7.3 / +8.0% and decode +2.3% (D4K, 78 generated) /
        # +3.5% (D29K, 88 generated).  The individual switches were also
        # screened: STRATA_QSA_ROWS, STRATA_EXPDEC and STRATA_DEQUANT_WIDE
        # added nothing on top of the series, and STRATA_ATTN_DAILY with
        # STRATA_ATTN_V3=0 was within noise, so the series stays one switch.
        STRATA_SM75_PERF = "1";
        # STRATA_PF_FUSED_SM75 (the fused int8 prompt experts on Turing) is not
        # carried: without STRATA_PF_FUSED it is inert on this native pack
        # (requested() needs =1; the engine printed no fused-path line in the
        # first screen), and with both set (2 runs an arm, 2026-11-04, DFlash2
        # on) prompt read was -2.5% / -0.9% / -0.3% at 4,252 / 3,477 / 26,134
        # with the answers identical and still no fused-path line.  The other
        # opt-ins outside the series (STRATA_PA_V2T, STRATA_SELECT_SIMT) changed
        # the answers and showed no consistent win in the screen, so they stay
        # off too.
        # The 1 GiB resident host tier (--resident-budget-gib, STRATA_RESIDENT_PIN
        # and STRATA_RESIDENT_HEADROOM_GIB with it) is gone with hostTierGib = 0:
        # it is mutually exclusive with --kv-grow, and the elastic K/V above buys
        # more (+1,643 slots, both reads and decode faster).  The variables are
        # dropped rather than left set, so nothing here implies a tier that the
        # engine is not running.
        #
        # STRATA_KV_GROW_HOLD=1: keep the longest parked conversation's K/V cells
        # mapped while it is parked, instead of trimming the region to the current
        # request and re-growing (which moves experts and costs a quiesce) on the
        # restore.  Cost: those cells stay out of the expert cache while parked -
        # ~17 slots for the 2.4k interactive conversation, so this is cheap at the
        # size that matters here.
        STRATA_KV_GROW_HOLD = "1";
        # v0.1.40 changed the file tier's default: on Linux the reads go unbuffered
        # when the file cache cannot keep the returning experts (#1194), and this box
        # (7.4 GiB RAM, shared with whatever is parked) is decided that way.  Unbuffered
        # is 2x slower here: the same cell (28160 chunk, 27575-token prompt, 256 gen)
        # reads in 52,095 ms (529.5 tok/s) unbuffered against 26,282 ms (1049.5
        # tok/s, and 26,919 ms on the deployed 0.1.38 stack) with the page cache -
        # the file tier's reads and the DAX window's registered pages want the file
        # cache, which is what 0.1.38's default was.  Upstream's force arm.
        STRATA_UNBUFFERED_LOAD = "0";
        # tiberius: a small pinned staging ring (4) still wins, but by ~1% at
        # v0.1.40.2 rather than the 16% of the 2026-09-30 measurement: the default
        # for a file/mmap source is now 4*threads (128), and unsetting the variable
        # measured 26564 ms (1038.4 tok/s) against 26282 ms (1049.5) with 4
        # (2026-10-08, 2 runs/arm).  Kept at 4.
        STRATA_STAGER_RING = "4";
        # STRATA_PREFILL_ROUTED_STREAM was screened 2026-11-04 and is NOT carried: it is
        # active on this build (its own log line) but costs +39..+88% prompt read on
        # >=1k-token chunks and +38% at 26,134 (both depths), i.e. it serialises the
        # copies the ordinary DAX walk overlaps.  Evidence: strata-tuning-next.md,
        # "Round 2 campaign results" (block A).
        # tiberius: the routed-only staging override is RETIRED as of the v0.1.40.2
        # bump.  It pinned the streamed ring to 8 slots (STAGE) for every chunk
        # size, which won 19% fewer streamed bytes at v0.1.38 (2026-09-30: 2409 tok
        # 12.56 -> 10.57 s).  Re-measured 2026-10-08 on the deployed shape (28160
        # chunk, 27575-token prompt, 256 gen, page-cache tier, 3 runs) the override
        # now COSTS 10.3% - see the --prefill comment; unset, the engine uses
        # v0.1.39's byte-budget ring (#583, default on), and STRATA_RING_BYTES=0
        # measured worse (27066 ms / 1019.2 tok/s).
        # v0.1.41 turned the CPU share ON by default where it measured it (CUDA
        # builds, one GPU, no batch slots - this box qualifies): chunks below
        # 1,024 tokens hand the decode CPU pool the non-resident experts few of
        # their tokens route to instead of streaming them over PCIe (upstream's
        # default reads as `auto` with STRATA_PREFILL_CPU_SHARE_MAX clamped to
        # 1024; the release notes measure -20..-35% on 512/1000-token prompts on
        # a 3060, a P100 and a 5070, 8/8 pairs each).  That win does not
        # transfer here: measured 2026-10-09 on the deployed 0.1.41 (/data/ab9*,
        # production config, 3 counterbalanced pairs, fresh engine per run), the
        # share-eligible cells read 723 and 579 tokens in 5,836 / 5,433 ms with
        # the share against 5,812 / 5,382 ms with it off (+0.4% / +0.9% - no
        # win, slightly slower), and a 9,491-token control above the window is
        # unchanged.  The prompt path here is bounded by the Optane read of the
        # pack (a sub-1K chunk reads ~26-31 GB of it), not by the PCIe stream
        # the share relieves, so splitting the read between CPU and GPU buys
        # nothing.  It also rounds differently (upstream's mean first-token KL
        # against the share off is ~0.004), so with no win there is nothing to
        # pay that for.  Unset the variable to adopt the new default; "0" is
        # upstream's documented escape hatch ("the output is then the 0.1.40.3
        # bytes").
        STRATA_PREFILL_CPU_SHARE = "0";
        # tiberius: v0.1.42's two CUDA decode defaults, both measured on this
        # box (2026-10-11, production config, fresh engine per run, counter-
        # balanced; the ab8 decode cells - 4292-token read + 256 gen, then
        # 3517 + 256 - with the prompt read as the control).  The arms:
        # parity (both 0.1.41 answers), ts7, pcie and the unset defaults.
        # Measured twice: /data/ab10* (built on trajanus) and /data/ab10n*,
        # the tiberius-native build that ships - same conclusions, and the
        # numbers below are the native run's.
        #
        # STRATA_ROUTE_TAIL_SKIP=7: a missed expert that every token of a
        # verify window routes at rank 7 or lower is skipped.  Upstream's
        # default, set explicitly so a future default flip cannot silently
        # move this box.  It is a big win HERE, far above upstream's +10..20%
        # on 12-16 GB cards: decode 21.30 -> 29.50 tok/s (+38.5%) on the 4292
        # cell and 26.03 -> 34.50 (+32.5%) on the 3517 cell (3 runs per arm;
        # the within-arm spread is +-0.1 tok/s), with the prompt read as the
        # control within noise in both runs (-0.2%/+0.1% and -2.5%/-1.4%, the
        # latter carried by one slow parity read).  The pool + plan time per
        # decode window drops 104.8 -> 63.0 / 85.6 -> 50.4 ms (-40% / -41%),
        # the acceptance-free form of the same win.  The mechanism: this box's
        # 6,282-slot cache of 24,576 experts misses enough for the skip to pay
        # - 14.1K-22.9K missed experts skipped of 15.2K-24.5K entries per cell
        # - and every skip removes a DMA plus its compute.
        # It changes answers slightly (upstream's mean first-token KL 0.0058
        # on an RTX 3060 IQ3_XXS, top-1 agreement 97.7%, PPL x1.011; their
        # HumanEval and reasoning sets did not move beyond their own noise):
        # accepted for the decode win, like STRATA_BF16_TC; =0 is upstream's
        # documented escape hatch (with STRATA_PREFILL_CPU_SHARE=0 it is the
        # exact 0.1.41 recipe).
        STRATA_ROUTE_TAIL_SKIP = "7";
        # STRATA_PCIE_FRAC_DEFAULT=old: v0.1.42 replaces the start-up link
        # probe that sets the missed-expert split with a rule that times the
        # CPU pool (~10 s, steps of 0.05 between 0.10 and 0.60, at most three
        # changes).  On this box the rule moved the share UP on every run that
        # used it - 0.34 -> 0.50, "the CPU pool takes 328 us per missed expert
        # (6.2 GB/s of expert bytes), the link 12.2-12.3 GB/s" - and decode
        # LOST at it: 21.30 -> 19.80 tok/s (-7.0%) and 26.03 -> 24.27 (-6.8%)
        # with the tail skip off, and 29.50/34.50 -> 29.40/32.80 (-0.3% /
        # -4.9%) with it on.  The pool here is slower per expert than the
        # link, so the split the rule computes costs decode; the start-up
        # probe's auto share was already the control in the ab8 campaign
        # (explicit 0/0.5/1.0 fractions: no win).  "old" is the variable's
        # only other value; unset adopts the measured rule.
        STRATA_PCIE_FRAC_DEFAULT = "old";
        # tiberius: v0.1.43's adaptive overlap - the adaptive tier's copies land
        # while the next verify window runs, each layer waiting on its own copies
        # (upstream's AdaptGate).  On Linux CUDA the feature is on by default, but
        # it is SKIPPED in the resident RAM mode this box runs unless
        # STRATA_ADAPT_OVERLAP_RESIDENT=1, so the deployed default already has it
        # off; =0 pins that, so a future default flip cannot move this box.
        # Measured 2026-10-12 (ab11: 3 counterbalanced runs per arm, P1
        # 4292-token / P2 3517-token decode cells, per-arm spread <=0.1 tok/s;
        # /data/ab11-*): the RESIDENT=1 opt-in read 25.6 / 30.3 tok/s against
        # 27.2 / 35.2 with it off (-5.8% / -14.0%) and streamed more file bytes,
        # so it stays off here.
        STRATA_ADAPT_OVERLAP = "0";
        # tiberius: the dense GEMMs on the FP16 tensor cores.  Turing has FP16
        # tensor cores and no BF16 ones, so cuBLAS served the dense (non-expert)
        # GEMMs - 482 calls, 335.7 ms of a 9.2 s prompt - with its FP32 SIMT
        # fallback (magma_sgemmEx_kernel).  Through v0.1.38 this was a local
        # patch (STRATA_DENSE_FP16, now retired); v0.1.39+ ships the same path
        # natively (bf16_path() in gemm.cu, #540/#655) and this flag selects it:
        # bf16 -> fp16 is exact for operands inside fp16's range, the
        # accumulation stays FP32, finite values past the range are clamped to
        # +-65504 rather than going Inf, and it is OFF by default on compute
        # capability 7.5 (the ready-made engine's RTX 20 policy) so an explicit
        # =1 is needed here.  It rounds differently from the BF16 SIMT fallback,
        # so the prompt-path state hash moves - hence opt-in.  Measured
        # 2026-10-01 on the real corpus, 3 runs/arm, same binary, on vs off (the
        # retired local implementation, same design): 4292-token prompt
        # 10,350 -> 9,845 ms (-4.9% mean, -5.8% median), 3514-token
        # 9,782 -> 9,179 (-6.2%); total kernel time 1564 -> 1302 ms (-16.8%).
        STRATA_BF16_TC = "1";
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
      }
      // lib.optionalAttrs (cfg.kv == "int8") {
        # Rotated INT8 K/V (Hadamard) for the int8 lane.  layer.cpp:568 makes this
        # `st.kv_rot = st.kv_q4 || (st.kv_int8 && g_kv_int8_rot)`, so it is a no-op
        # for fp16/q4_0/k8v4.  Measured 2026-10-03 (/data/kvrot, post-#547 engine,
        # fresh engine per cell, 2 counterbalanced passes; expert set pinned at
        # 3896 slots for the fidelity cells): KL(ref=fp16 || int8) 5.24e-1 ->
        # 7.98e-2, top-1 restored, the 8-token greedy output bit-exact fp16 where
        # unrotated flips; capacity unchanged (6288 slots / 5554 borrow), prefill
        # -0.24% aggregate, decode ~-1% (three FWHT-256 launches per layer per
        # token).  The snapshot tag moves +16, so rotated and unrotated int8
        # checkpoints never restore into each other - one cold re-prefill follows.
        STRATA_KV_ROT = "1";
      };
      port = upstreamPort;
      # upstream's serve layer checks the Host header on every request (the
      # DNS-rebinding fix, server.py parse_request): it answers to localhost and
      # *.localhost, IP literals, the bind address and, when it listens beyond
      # loopback, this PC's own hostname and hostname.local.  It is loopback-only
      # now, while the lease proxy relays the client's Host unchanged, so the
      # names clients actually send must be listed here: 127.0.0.1, localhost
      # and every IP literal pass by themselves; `tiberius` and `tiberius.local`
      # used to come from the bind address; the MagicDNS FQDN always needed this
      # list.  NOTE this key is read by the SERVER from the config JSON - the env
      # dict above only reaches the engine, so STRATA_ALLOWED_HOSTS there does
      # nothing (measured: the server logged no "also answers to" line and 403'd
      # the FQDN).
      allowed_hosts = [
        "tiberius"
        "tiberius.local"
        "tiberius.tail01b8d.ts.net"
      ];
      # Loopback only: the lease proxy is the sole way in (see
      # tiberius-strata-lease below), and clients keep the URL they already use
      # (http://tiberius:8080/v1).  --host is passed on the command line as well
      # - it wins over this key (server.py: a.host = a.host or cfg.get("host")
      # or "127.0.0.1") - so neither one alone can reopen the port.
      host = "127.0.0.1";
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
      if [ "${lib.boolToString cfg.formatOptane}" != "true" ]; then
        echo "/dev/pmem0 carries a '$fstype' filesystem, not xfs: refusing to format it." >&2
        echo "Set services.tiberius-strata.formatOptane = true to wipe it." >&2
        exit 1
      fi
      mkfs.xfs -f -K -m reflink=0 -d su=2m,sw=1 /dev/pmem0
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
        because upstream's gguf_split_paths() makes a missing sibling shard fatal
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
        131K of window costs ~830 expert-cache slots.  Above 262K the prompt is
        outside the model's native window: the card says 262,144 natively and
        extensible to 1,000,000 with YaRN (rope_type yarn, factor 4.0, factor
        2.0 recommended near 524K), the GGUF and the HF config both declare
        262,144 with rope_type default, and no --rope-scale is passed, so the
        engine extrapolates.  Measured 2026-10-29 at 524,288 (v0.2.7, route
        prior on): the engine runs and a 478K prompt answered a mid-document
        needle, but the cache shrank 6,257 -> 4,221 slots, the 128K cell lost 18%
        decode (49.3 -> 40.3 tok/s) and hit fell 99.1 -> 90.8% - and that is the
        regime the card recommends YaRN for.  A longer lane is CLI-only: the
        engine implements YaRN (--rope-scaling yarn --rope-scale 4
        --yarn-orig-ctx 262144) and the model file carries no rope.scaling
        keys; the card's factor is 4.0 for 1M and 2.0 near 524K, and it warns
        that static YaRN costs short-text quality.  Older cells without routing
        thrashed harder: 524K -> 14.5 tok/s / 70% hit, 786K -> 10.6 / 54%.
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
        slots; decode 20.3/20.7 pre-rotation; the module adds STRATA_KV_ROT=1,
        i.e. both rotated, which cuts the near-tie KL against fp16 6.6x
        (0.524 -> 0.0798), restores its top-1 where unrotated flips, and costs
        -0.83%/-0.96% on identical streams); fp16 2048
        B/cell (the ceiling: 4607 slots at
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
      default = 0.0;
      description = ''
        GiB of the hottest profile-ranked experts the GPU cache does not hold kept
        in ordinary RAM (upstream's --resident-budget-gib, a float so a lane can
        ask for e.g. 0.5).  0 (the default) keeps the plain mmap path, and it is
        required for --kv-grow: the flag sets resident_cpu_experts, which the
        kv-grow gate excludes.  1.0 was the setting until 2026-11-01 - the old
        --resident-cpu-mib 1024, worth ~8% off the CPU pool on pre-router
        traffic (22% misses).  With the route prior at 98% hit, the elastic K/V
        that 0 enables measured +27% expert slots and +8.8% read / +16.5% decode
        on the 4,252-token cell, so the tier loses.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = ''
        The public interactive port (on 0.0.0.0), served by the lease proxy.
        The background door is 8090; the engine itself listens on 127.0.0.1:8081
        and is not reachable directly.
      '';
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
    systemd.services = {
      sshd.serviceConfig.ExecStartPre = [
        "+${pkgs.coreutils}/bin/mkdir -p /var/empty"
      ];
      strata-optane-prepare = lib.mkIf cfg.mountOptane {
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

      tiberius-strata = {
        description = "Strata ${cfg.model} (Qwen3.8-Flash-Next) on the RTX 2080 Ti / Optane";
        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" ];
        # Conflicts= stops the peer without ordering the shutdown, so the peer
        # must also be in this list: without it a manual flip can initialize
        # CUDA on the next engine while this one still holds the 22 GB card.
        after = [
          "network-online.target"
          "nvidia-persistenced.service"
          "tiberius-qwen38.service"
          "tiberius-qwen38-uncensored.service"
          "tiberius-ninfer.service"
        ];
        # One GPU: never resident beside the vLLM lanes.
        conflicts = [
          "tiberius-qwen38.service"
          "tiberius-qwen38-uncensored.service"
          "tiberius-ninfer.service"
        ];
        # WantsMountsFor=, not RequiresMountsFor=: both of these mounts can
        # legitimately appear after multi-user (/dev/pmem0 enumeration; the ZFS
        # import of zdata).  A failed Requires= would cancel this unit's start
        # job with result 'dependency' - systemd never retries that (Restart=
        # covers only process failures, and OnFailure= never fires because the
        # unit stays inactive rather than failed), so the lane would wait for a
        # manual start.  Wants= keeps the pull-in and the After= ordering, but a
        # late mount becomes an ordinary ExecStartPre failure that the bounded
        # Restart= retries.  Requires systemd >= 256; tiberius runs 260.4
        # (verified on-box with a systemd-analyze verify probe).
        unitConfig.WantsMountsFor = [
          cfg.dataDir
          cfg.modelsRoot
        ];
        # Restart=on-failure + 10s backoff alone defeats systemd's default start
        # limit, so a permanently broken start (missing pack, empty /optane, bad
        # profile) loops forever in "activating (auto-restart)" and never shows
        # in systemctl --failed.  Bound it so the failure is visible.  These are
        # [Unit] directives: in serviceConfig systemd accepts only the legacy
        # StartLimitBurst spelling and silently drops StartLimitIntervalSec, so
        # both live at the unit level, not in the [Service] block below.
        # 10 x RestartSec=10 s after the first failure: wider than the mounts'
        # own failure windows (30 s pmem device timeout, 60 s ZFS import loop,
        # 90 s systemd device default), still bounded so a permanently broken
        # start is visible in systemctl --failed.
        startLimitIntervalSec = 600;
        startLimitBurst = 10;
        environment = {
          LD_LIBRARY_PATH = "${config.hardware.nvidia.package}/lib";
          # The bundled web app is off: serve/server.py 404s its pages, assets
          # and /settings when this is set.  The API is unaffected, and the
          # /settings sidecar (which would sit next to the read-only store
          # config) is never written.
          STRATA_NO_WEB = "1";
        };
        serviceConfig = {
          Type = "exec";
          LimitMEMLOCK = "infinity";
          Restart = "on-failure";
          RestartSec = "10s";
          ExecStartPre = [
            "${pkgs.coreutils}/bin/mkdir -p ${cfg.stateDir}"
            # The pack's experts.bin is what puts the expert reads on the DAX
            # Optane (6.8 GB/s).  A native pack built WITHOUT `iq_pack.py
            # --experts-bin` is legal to the engine: it silently falls back to
            # reading the model's GGUF shards in place.  This box keeps shard 1
            # (54.8 GB) on the /data SATA pool (407 MB/s measured), where that
            # fallback serves 1 tok/s decode and 28 tok/s prefill and says
            # nothing worse than "the GGUF in place" in its log - measured
            # 2026-10-28, see docs/exec-plans/active/strata-pack-restore.md.
            # Fail the start instead of serving 20x slower.
            "${pkgs.coreutils}/bin/test -f ${cfg.dataDir}/packs/${lane.pack}/experts.bin"
            # /data can be late as well: without this gate a missing shard
            # surfaces as a dangling symlink and the engine dies ~40 s into
            # loading it, instead of as a clean, retryable start failure.
            "${pkgs.coreutils}/bin/test -f ${cfg.modelsRoot}/${lane.models}/${lane.shard1}"
            # upstream's gguf_split_paths() demands every shard named by --native's
            # "-of-NNNNN" suffix beside it, and it validates the GGUF's own split
            # metadata too, so shard 1 cannot be passed alone or under a made-up
            # name.  nativeDir is therefore assembled here with BOTH shards as
            # symlinks under their real split names; --native and --ple-gguf then
            # point inside it.  ln -sfn is idempotent and replaces a stale link.
            "${pkgs.coreutils}/bin/mkdir -p ${nativeDir}"
            "${pkgs.coreutils}/bin/ln -sfn ${cfg.modelsRoot}/${lane.models}/${lane.shard1} ${nativeDir}/${lane.shard1}"
            "${pkgs.coreutils}/bin/ln -sfn ${cfg.dataDir}/ple/${pleFile} ${nativeDir}/${pleShard}"
            # Disk sessions (POST /slots/0?action=save|restore).  A SAVE streams
            # the K/V straight from the pools into the file ("without a full host
            # capture", generate.cpp): a 250k conversation measured 3.89 GB in
            # 5.1 s on 2026-11-01.  A RESTORE is NOT streamed - session_file_read
            # fills a SavedConversation in host RAM first (3,727 MiB at 250k plus
            # the 384 MiB floor, refused against 2,050 MiB available), so the disk
            # path only restores conversations whose image fits free RAM (~50k and
            # below) - and, unlike a park, it survives a background request and a
            # restart.
            "${pkgs.coreutils}/bin/mkdir -p ${cfg.dataDir}/sessions"
            # pmem park tier (round 7/8, validated 2026-11-05): a refused RAM
            # park is written as a v1 session file under this directory and
            # restored streamed on a later turn.  Boot re-admission of *.park
            # files is not implemented, so pre-clean anything an unclean
            # shutdown left behind; the engine recreates the tier's metadata
            # at start.  6 GiB / 4 slots keeps one long (~3.6 GB) park resident
            # plus short ones; the 4096 MiB reserve keeps session/SAVE space.
            "${pkgs.coreutils}/bin/mkdir -p ${cfg.dataDir}/parks"
            "${pkgs.findutils}/bin/find ${cfg.dataDir}/parks -maxdepth 1 -name '*.park' -delete"
          ];
          ExecStart = lib.escapeShellArgs [
            "${python}/bin/python3"
            "${cfg.package}/share/strata/serve/server.py"
            "--engine"
            "strata"
            "--config"
            (toString strataJson)
            # Loopback only, on upstreamPort: the lease proxy owns the two
            # public doors (8080 interactive, 8090 background) and is the only
            # way in.  A background client that could reach the engine directly
            # would bypass the lease - which is exactly the request pattern that
            # clears the interactive conversation.
            "--host"
            "127.0.0.1"
            "--port"
            (toString upstreamPort)
            # enables POST /slots/0?action=save|restore; the directory holds the
            # session files (a 250k-token one is ~4.3 GB, /optane has 40 GB free,
            # and the default --session-min-free-mib 4096 leaves room)
            "--slot-save-path"
            "${cfg.dataDir}/sessions"
          ];
        };
      };

      # The engine holds ONE live conversation, so a background prompt arriving
      # between two of the user's turns (hindsight on pius: 19-36k tokens
      # through http://tiberius:8080/v1) clears it and the next turn has to
      # re-read the whole chain - 164 s at 250k tokens.  This front end leases
      # the engine to the interactive door and holds background requests while
      # it is leased; pkgs/strata-lease-proxy.py has the design notes.
      tiberius-strata-lease = {
        description = "Lease front end for Strata (interactive :${toString cfg.port}, background :8090)";
        # Follows the engine's own activation: parking Strata is a one-line
        # `wantedBy = lib.mkForce [ ]` in hosts/tiberius.nix, and the doors must
        # go with it - the parked vLLM lanes bind ${toString cfg.port} too, so a
        # proxy that stayed wanted would fight them for it on that boot.
        wantedBy = config.systemd.services.tiberius-strata.wantedBy;
        # Wants, not requires: restarting the engine must not take the doors
        # down with it, and this unit coming up must not restart the engine.
        # While the engine is away the proxy answers 502 instead of refusing.
        wants = [ "tiberius-strata.service" ];
        after = [
          "tiberius-strata.service"
          # The proxy resolves `pius` (MagicDNS, 100.121.87.116 on this box)
          # before it can classify a request; order after the resolver instead
          # of relying on the script's own 60 s retry.
          "nss-lookup.target"
        ];
        serviceConfig = {
          Type = "exec";
          Restart = "on-failure";
          RestartSec = "5s";
          ExecStart = lib.escapeShellArgs [
            "${python}/bin/python3"
            "${leaseProxy}"
            "--front"
            "0.0.0.0:${toString cfg.port}"
            "--back"
            "0.0.0.0:8090"
            "--upstream"
            "127.0.0.1:${toString upstreamPort}"
            # hindsight on pius keeps talking to :8080 (moving it to :8090
            # needs a tailnet ACL entry, and that portal is off this machine),
            # so its address - not its port - is what marks it as background.
            "--background-host"
            "pius"
          ];
          # Sockets and the journal, nothing else: the process writes no files.
          # The lease (600 s) and the hold cap (500 s) are the script's
          # defaults; STRATA_LEASE_SECONDS and STRATA_LEASE_HOLD_CAP override
          # them for a test.
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          RestrictAddressFamilies = [
            "AF_INET"
            "AF_INET6"
            "AF_UNIX"
          ];
        };
      };
    };

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
  };
}
