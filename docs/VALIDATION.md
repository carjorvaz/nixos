# Validation

Use `scripts/validate` as the default local validation entrypoint before committing or deploying changes.

```sh
scripts/validate
```

For a discoverable task menu with repository tools on machines that do not have
them installed globally, enter the dev shell and use the `justfile`:

```sh
nix develop -c just --list
nix develop -c just validate
```

The default validation is intentionally public-safe and non-mutating. It does not SSH to hosts, deploy, decrypt secrets, switch systems, or print full evaluated configurations. Nix may still use normal fetchers for flake inputs.

## What the default command checks

- `git diff --check HEAD --` for whitespace errors across staged and unstaged changes.
- `deadnix .` to prevent unused lambda parameters and dead declarations from accumulating.
- `nixfmt --check` to enforce consistent formatting across all tracked `.nix` files.
- `statix check .` for 13 Nix anti-pattern checks (bool comparisons, empty lets, deprecated syntax, unquoted URIs, etc.). The repository carries no `statix.toml`; the check passes with its default configuration.
- `nix flake show --allow-import-from-derivation --no-write-lock-file` for flake shape.
- `nix eval` of each NixOS host's `config.system.build.toplevel.drvPath`.
- `nix eval` of the nix-darwin `air` system output.
- `nix eval` of the current-system check names.
- `nix build --no-link` of the lightweight current-system `repo-harness-docs` check.
- `nix eval` of the `checks.x86_64-linux` check names.

When deadnix or nixfmt are not on PATH (outside the dev shell), those checks are skipped with a note rather than failing — the Nix evaluations still catch structural errors.

This is a good default for agent work on macOS because it catches most structural errors without attempting Linux builds locally.

## Optional stronger checks

Dry-run all x86_64-linux flake checks without building them:

```sh
scripts/validate --dry-run-checks
```

Build or run individual checks only when the local machine or configured builders can support them:

```sh
nix build --no-link .#checks.aarch64-darwin.repo-harness-docs  # on Apple Silicon Macs
nix build --no-link .#checks.x86_64-linux.repo-harness-docs    # on Linux or a Linux builder
nix build --no-link .#checks.x86_64-linux.firecrawl-module-generic-quality
nix build --no-link .#checks.x86_64-linux.firecrawl-unsafe-bind-rejected
```

The Firecrawl VM smoke test is heavier and Linux-specific:

```sh
nix build --no-link .#checks.x86_64-linux.firecrawl-nixos-smoke
```

## Tiberius NInfer fallback runtime

`ninfer-sm75` builds the pinned Turing fork natively with CUDA 12.9 and its
supported host compiler. `profiles/nixos/ninfer-qwen.nix` composes the server and
checksum-verified model preparation; no Python serving environment or container
is needed. Build the CUDA package on a capable Linux builder, not on Tiberius's
7.5 GiB host RAM. Its [package notes](../pkgs/ninfer-sm75/README.md) explain the
Turing operand-layout/cache-address fixes, full-range BF16 SIMT path, narrow W8
vocabulary/fused Q5 residual routes, and opt-in `mmaCheck`/`paddingCheck`/`gpuTests`
packages. GPU tests must run on dedicated SM75 hardware, not as automatic build
checks; the heavier tests stay outside the service closure.

```sh
nix eval --raw .#packages.x86_64-linux.ninfer-sm75.drvPath
scripts/validate --host tiberius
```

The manual fallback `tiberius-ninfer.service` serves `qwen3.8-27b` on port 8080, with no
LAN/WAN firewall opening. It uses one active sequence, a **131072-token context
and KV pool, INT8 KV, and no speculative decoding**. Speculation requires separate
latency and near-limit lifecycle qualification, even when its reservation fits.
Vision is disabled.
BF16 activation arithmetic retains its full-range original SIMT implementation;
the INT8 setting applies to KV, not activation precision.

Qualification includes exact beginning/middle/end retrieval at about 124.5K
uncached input tokens, substantial cached continuation, unrelated-prefix
replacement, zero-cache original-conversation recomputation, and oversized-input
rejection/recovery under service memory limits.
Cold near-limit prefill took about 27 minutes on this host; the cached follow-up
took seconds. Capacity fit alone is not a correctness or latency qualification.
Do not advertise the default vLLM runtime's 262144-token limit to NInfer clients;
other capacities and speculation settings require separate validation.

`tiberius-ninfer-prepare.service` downloads the 16.96 GiB artifact directly to
`/persist/ninfer`, resumes a `.partial` file, checks size and SHA-256, and atomically
publishes it read-only. It also verifies an existing artifact, refusing to
overwrite a corrupt file. Inspect and move a failed partial aside before retrying;
it is never silently accepted. The pinned HF revision is the v1 conversion that
matches this fork; newer HF `main` adds DFlash2 weights for a newer runtime. The
server runs as a dynamic unprivileged user with read-only model access and bounded
host RAM. Readiness requires `/health` success **and** the intended service,
package and settings. Pin the service's PID/invocation across readiness and live
checks: an automatically restored fallback can answer the same endpoint and model
alias. Neither an active unit alone nor fallback health qualifies a candidate.

Live checks are explicitly opt-in and must not run in public CI. During a
maintenance window, use a loopback SSH tunnel to port 8080 and run:

```sh
python3 checks/ninfer-api.py http://127.0.0.1:18080
python3 checks/ninfer-api.py http://127.0.0.1:18080 --long-context --recompute --context-size 131072 --timeout 7200
```

These check model discovery, exact-answer generation, reasoning separation, SSE
framing/usage, and a harmless arithmetic tool-result roundtrip. The longer check
uses the Responses API for cache-token accounting (this pin's Chat Completions
usage omits cache counts) and adds an
uncached near-limit prompt with beginning/middle/end retrieval, a cached
continuation with substantial cache reuse, unrelated-prefix replacement, and
HTTP 400 rejection of an over-limit prompt followed by successful generation.
`--recompute` additionally requires zero-cache recomputation of the original
conversation after replacement, unchanged input-token count, and exact equality
with its cached continuation; budget for a second cold prefill. `--long-context`
requires an explicit `--context-size` so a small test cannot
silently stand in for the configured capacity. It tokenizes and corrects the full
fixture before inference rather than extrapolating a short sample across 128K.
Allow enough request/first-event time for cold prefill, separately from the
between-event stall timeout; client changes require separate review.
Also inspect service restart/OOM counters and host/GPU memory after cold startup
and the complete request lifecycle.
Keep raw operational output outside the repo.

NInfer's Chat Completions API accepts **top-level** `reasoning_effort` (`none`,
`low`, `medium`, `xhigh`) and `enable_thinking`. Unlike the vLLM adapter,
it rejects these inside `chat_template_kwargs`; only `preserve_thinking` is
accepted there. Update client context metadata and request mapping separately
when changing backend; do not assume a vLLM-specific client overlay works unchanged.
The pinned server has no `--reasoning-effort` default override, even though its CLI
does. Explicit per-request effort avoids the artifact template's default.

`tiberius-qwen38.service` is the boot default; NInfer and its assets remain
available for manual fallback. The services conflict and their stop/start jobs
are ordered, so only one owns the GPU/API port. Temporary fallback: stop
`tiberius-qwen38.service` and start `tiberius-ninfer.service`; to return, stop
NInfer and start Qwen. For a durable backend change, update the host's `wantedBy`
selection and the client's context/reasoning mapping together.

## Tiberius Strata runtime

`strata-sm75` is the boot engine on Tiberius. It builds upstream Strata at pin
`fb58e0d` (v0.1.41) with three patches: `carry-1283.patch` (upstream PR #1283's
`bytes_needed` src accounting, rebased by its author; the PR lineage is #547 ->
#1042 -> #1283), `tiberius.patch` (a sliding DAX register window, decode-time
refill pinning with its straddle guard; generated on top of `carry-1283.patch`,
hence the order) and `no-web-ui.patch` (`STRATA_NO_WEB=1` turns off the bundled
web app, its pages/assets and `/settings`; the OpenAI-compatible API is
untouched). All three were regenerated against this pin at the v0.1.41 bump
(the changed lines are byte-identical to the v0.1.40.2 generation; two hunks
were re-homed around upstream's new CPU-share block and serve report line).
The dense-FP16 tensor-core change that `tiberius.patch` used to carry
was retired at the v0.1.40.2 bump: upstream 0.1.39+ has the same path natively
(`bf16_path()`, #540/#655) and the module selects it with upstream's
`STRATA_BF16_TC=1` (opt-in on the RTX 20's compute capability 7.5). Build-time
greps fail the derivation if a flag or environment variable the module sets
disappears on a rebase.

The module holds `STRATA_PREFILL_CPU_SHARE=0`. v0.1.41 turns the CPU share on by
default for chunks below 1,024 tokens on one NVIDIA GPU, which changes the last
bits of an answer (upstream's mean first-token KL against the share off is
~0.004). Measured on the deployed engine, 2026-10-09 (`/data/ab9*`, production
config, 3 counterbalanced pairs, fresh engine per run): the share-eligible cells
(723 and 579 tokens) read in 5,836 / 5,433 ms with the share against
5,812 / 5,382 ms with it off -- no win, slightly slower -- and a 9,491-token
control above the window is unchanged. The prompt path is bounded by the Optane
read of the pack, not by the PCIe stream the share relieves, so the pin stays;
unsetting the variable adopts upstream's default.

The module also forces `STRATA_UNBUFFERED_LOAD=0`: v0.1.40's #1194 makes the Linux
file tier read unbuffered when the file cache cannot keep the returning experts,
which is what this 7.4 GiB box is decided as, and that measured 2x slower here
(52.1 s vs 26.3 s for the same 27575-token prompt; re-measure of the `--prefill`
choice at the bump is `/data/chunkint8/summary-1402.txt`).

The same campaign retired the `STRATA_PREFILL_RING=8` routed-only staging override:
at v0.1.40.2 it cost 10.3% on the 27575-token cell (26,282 -> 23,823 ms,
1049.5 -> 1157.9 tok/s, three runs each side of the change), so the engine's own
#583 byte-budget ring is used.  `STRATA_STAGER_RING=4` and `--prefill 28160` were
re-confirmed (+1% and the fastest chunk measured), `STRATA_RING_BYTES=0` and
`STRATA_SH_FORK_LATE=0` measured worse or neutral, and the coder lane beat its
v0.1.38 baseline by +6% read / +8.5% decode at a stricter KV.

The optional `pkgs/kernel-patches/fsdax-longterm-pin.patch` plus the
`fsdax_longterm_pin=1` parameter pin FSDAX pages on Tiberius only. This is
**unsafe in general**: pinned FSDAX pages cannot be migrated, truncated,
hole-punched or hot-unplugged. It is acceptable here only because the pinned
object is a read-only, never-truncated `experts.bin` on permanently attached
pmem. The parameter defaults off; without it the kernel behaves like stock.

Model data is prepared on the host, not in the store, under
`/optane/strata-data` (`packs/`, `ple/`, `mtp/`).
`strata-optane-prepare.service` reconciles the fsdax namespace and the
XFS (`dax=always`) mount; it is idempotent. `formatOptane = true` is the
destructive opt-in: it runs `mkfs` and will reformat a foreign filesystem on the
namespace.

`tiberius-strata.service` conflicts with the vLLM lanes and is ordered so the
peer releases the GPU before it starts. It binds `0.0.0.0:8080` with a
Host-header allowlist and no API key -- tailnet-only in practice, since the
firewall opens nothing and `tailscale0` is trusted. It serves one request at a
time (extra requests queue), and its conversation cache is RAM-only, so a
restart loses it.

Validation for the engine, module and its wiring:

```sh
nix eval --raw .#packages.x86_64-linux.strata-sm75.drvPath
scripts/validate --host tiberius
nix eval .#checks.x86_64-linux --apply builtins.attrNames
```

The current-system check names include `tiberius-strata-module-eval`, which
asserts the rendered unit's `[Unit]` start-limit keys, its `After=` ordering,
the prepare unit's ordering, and the kernel patch/parameter wiring.

Live checks are explicitly opt-in and must not run in public CI. During a
maintenance window, use a loopback SSH tunnel to port 8080 and confirm:

- `/health` returns status `ok` with the served model name.
- A chat completion with `chat_template_kwargs.enable_thinking=false` returns no
  think block.
- The tailnet FQDN `Host` passes the allowlist while an unknown `Host` gets 403.

Cold prefill can take minutes and decode runs at roughly 20 tok/s, so budget
timeouts accordingly. Confirm the serving unit and PID identity before and after
the checks: another service can answer the same port and model name.

## Tiberius chassis fan control

The two populated chassis fans (SYS_FAN_1, SYS_FAN_3; the other four headers
are empty) hang off the BMC, not the host, and are the loudest part of the box:
under the inference load the automatic curve held SYS_FAN_1 at a fixed 100%
duty (1400 RPM) and swung SYS_FAN_3 between 61% and 90% (1200-2400 RPM) with
the CPU, while the same load kept the Optane DIMM at ~82C of its 85C
upper-critical. The BMC web UI and Redfish expose no fan control; the knob is
the Tyan/MiTAC OEM fan IPMI (the S8036 homelab writeup and the MiTAC KB
document the same family):

```sh
# per channel: duty 0x00-0x64 (percent, decimal in hex), 0xfe read back,
# 0xff returns the channel to automatic control
ipmitool raw 0x2e 0x05 0xfd 0x19 0x00 <channel> <0x00-0x64 | 0xfe | 0xff>
# global automatic fan control: 0x00 off, 0x01 on, 0xff read back
ipmitool raw 0x2e 0x06 0xfd 0x19 0x00 <0x00 | 0x01 | 0xff>
```

A channel under a manual duty reads back as `0x80|duty` (60% = `bc`), and
`0x06 ... 0x01` does not clear per-channel overrides (measured 2026-10-09):
the restore path is the per-channel `0xff`. Channel map measured on this
board: PWM 1+3 = SYS_FAN_3 (one zone, both carry its value), PWM 2 =
SYS_FAN_1; PWM 0/4/5/6 are unpopulated. `0x2e 0x44` is not implemented on this
firmware (0xc1).

`hosts/tiberius.nix` runs `tiberius-fan-quiet.service` from a 60s timer. It
picks one of two tested duties from the chassis sensors each tick: 30% while
cold (`CPU_Temp`, the Optane DIMM and the VRM all <= 60C; idle and the
GPU-bound vLLM lanes sit near 40C; measured 500 / ~900 RPM) and 50% otherwise
(the strata engine soaks the DIMM to ~82C of its 85C critical; measured
800 / ~1300 RPM, the same thermal envelope as the automatic curve's 60-90%,
because these two fans barely move the DIMM either way). It re-asserts the pin
after a BMC config reset and hands the fans back to the BMC when hot -
CPU_Temp >= 95, P0_MC0_DIM_CH_A >= 84 (critical 85) or CPU_MOS >= 92 - staying
off until the chassis cools below CPU 70 / DIMM 75 / VRM 70, so the pin cannot
hide a rising trend and the fans cannot oscillate at the trip points.

While the timer runs, an ad-hoc duty write to PWM 1/2/3 is transient: the next
tick rewrites that tick's tier duty. To return to BMC control on purpose:

```sh
systemctl stop tiberius-fan-quiet.timer
for ch in 1 2 3; do ipmitool raw 0x2e 0x05 0xfd 0x19 0x00 "$ch" 0xff; done
```

```sh
ipmitool sdr type fan                             # RPMs
ipmitool raw 0x2e 0x05 0xfd 0x19 0x00 1 0xfe      # 9e/b2 = pinned, else auto
systemctl list-timers tiberius-fan-quiet.timer
journalctl -u tiberius-fan-quiet -n 20
```

## Tiberius vLLM runtime and memory checks

The default `qwen38-sm75` runtime uses pinned upstream patches and Python wheels, native
CUDA 12.9/GCC 14 tools, native paged prefill, and SM75 Tensor Core speculative
attention for head-dimension-256 FP16/INT8/INT4 KV caches. Models, versioned runtimes,
and compilation caches live under `/persist/qwen38-sm75`. First-use CUDA extension
compilation uses the pinned toolchain and persistent cache. Supported SM75 GDN
prefill state updates use native FP16 Tensor Core operands with FP32 accumulation;
unsupported shapes retain FLA. `VLLM_TURING_GDN_STATE=0` selects the reference path
for controlled comparisons.

SM75 D256 causal prefill also uses a 256-key tile with FP32 register accumulation.
It preserves the existing paged gather and FP16/INT8/INT4 numerical budgets;
unsupported layouts and autograd retain PyTorch SDPA. The pinned Torch header is
verified and copied into the JIT cache, never edited in the installed wheel.
`VLLM_TURING_PREFILL_TILE=0` selects the original attention path for comparisons.

```sh
nix eval --raw .#packages.x86_64-linux.qwen38-sm75.drvPath
scripts/validate --host tiberius
```

`tiberius-qwen38-prepare.service` prepares checksum-verified model assets and
atomically publishes the patched runtime before `tiberius-qwen38.service` starts.
The first preparation needs network access; serving verifies the preparation
manifests and runs offline. `tiberius-qwen38-warmup.service` follows the server's
start/stop lifecycle without gating server or boot readiness. Its 25-minute limit
covers health polling and first inference; failures must remain visible without
stopping the server.

Run the packaged regressions as root on Tiberius. The GPU checks require a
bounded maintenance window. Record and stop whichever inference service owns the
GPU, including `tiberius-ninfer.service` when it is active, and confirm no GPU
process survives before testing. Restore the previously active service afterwards
and verify its identity and health; do not inadvertently change the selected
backend just because its checks were run.

```sh
qwen38-sm75-check attention
qwen38-sm75-check prefill
qwen38-sm75-check prefix
qwen38-sm75-check gdn
qwen38-sm75-check downloads
```

These cover FP16/INT8/INT4 attention against FP32 references, packed zero points
and Hadamard rotations, real INT4 cache writes, and same-address CUDA graph replay.
They also cover fresh-prefill exclusion from decode graphs, padded request rows,
poisoned unused storage, native selector JIT compilation, and paged prefill through
262144 tokens with non-contiguous storage. Download
fixtures cover valid resume, corrupt/oversized partials, rejected ranges, persistent
checksum failure, and interrupted transfers. GDN checks cover partial and packed
sequences, padded strides, FP16/FP32 or absent initial state, chained recurrent
updates, fixed-address graph replay, and dispatch/reference fallback. Prefill
checks additionally change inputs and page tables across graph replay and verify
exact opt-out, autograd, unsupported-layout, and original-error fallback behavior.
The CPU-only `prefix` check exercises real allocator/hash/CoW metadata, scheduler
boundaries, and rejection of hash units too small for speculative lookahead.

The 262144-token native-context MTP4 profile is single-sequence and requires a
dedicated GPU. It uses Hadamard-rotated INT4 KV, not KVarN, while Mamba state remains
FP16. The validated 2048-token prefill batch fits its 1632-token hybrid pages.
Smaller batches use private sub-block state rather than being categorically
unsupported, but need separate scheduling, cache, and performance validation.
Account for CUDA graphs, speculative state,
and the 1 GiB shared FP16 prefill workspace as well as the **5.5 GiB INT4 KV pool**
when changing memory limits. The default profile uses MTP4 with
`--prefix-match-unit 16`; hash granularity is independent of the physical page.
Do not infer admission safety from the nominal token capacity of the pool.
The cache patch retains attention's speculative safety drop and saves recurrent
state one hash unit earlier; it does not admit the unsafe tail to improve hits.
Near-limit cold prefill can take many minutes.
Allow enough time for the first streamed event in clients as well: the mutable
OMP model entry uses `compat.streamFirstEventTimeoutMs: 1800000`. Keep the
between-event stall timeout separate so a stalled decode still fails promptly.
The Tiberius OMP overlay also disables speculative background compaction with
`compaction.asyncEnabled: false`: another long prefill occupies its sole sequence
slot and competes with the live conversation for KV cache. Normal threshold
compaction remains enabled. The server defaults omitted reasoning effort to
`medium`; explicit per-request `low` and `xhigh` remain available. Client effort
must reach `chat_template_kwargs.reasoning_effort`, not merely enable thinking.

The service compiles with `mode=VLLM_COMPILE` and
`cudagraph_mode=FULL_AND_PIECEWISE`; the GDN attention backend only supports
uniform-batch full graphs, so piecewise is the effective graph mode either way.
The first boot after a cache change compiles (~1 min) into the persistent
`torchinductor` cache; later boots initialize in seconds. Measured 2026-09-16
at 2k/8k-token prompts, same flags: 95.0/98.5 tok/s against 85.6/75.6 with
`mode=NONE` (+11%/+30%). Never compare a cold-cache boot with a warm one.

The 262k lifecycle was re-qualified on the running service on 2026-09-16:
a 248,098-token cold prompt retrieved a middle fact in 683 s; the cached
continuation served 246,432 cached tokens and answered in 8.8 s; a different
200k prompt replaced it; the original recomputed cold (0 cached) in 685 s and
answered correctly; a short prompt took 0.34 s; zero preemptions, no restart.
Quality on the same runtime: GSM8K 94.5% (n=200) and perplexity 10.88 over
25,092 tokens through the upstream quality battery.

An optional second model is packaged but not started at boot: the uncensored
W4A16 checkpoint with a 40k-row int8 draft head and int4 MTP
(`systemctl start tiberius-qwen38-uncensored`, port 8082, conflicts take the
production engine down first). It passes the same quality gates (GSM8K 96.5 %,
PPL 10.94) and a 100k lifecycle 5/5; its serving pool is 4.5 GiB at 235k, but
quality harnesses need a smaller pool because `prompt_logprobs` has no scratch
at the int8 full-vocabulary lm_head.

The unit reads an optional `serve.env` file from the runtime root
(`EnvironmentFile=-/persist/qwen38-sm75/serve.env`), so environment knobs can
be changed without a rebuild. Measured profiles:

- **MTP history lookup** (on by default: `VLLM_MTP_LOOKUP=1` in the unit
  environment, tunable through `serve.env`). Before drafting, the proposer asks
  whether the tokens the request just produced already occurred earlier in that
  request's own context; if so it proposes that continuation and skips the
  drafter entirely. Greedy requests only, and only after a step that accepted
  every draft it was given, so prose cannot start a chain on a coincidence.
  Measured against MTP on the same runtime and host: chat unaffected to within
  noise (2k 90.4/91.0, 8k 88.3/89.2-90.3, 32k 76.1/76.1, 64k 68.3/68.4,
  128k 57.3/57.9 tok/s), while a 60k-token verbatim-reproduction task reads
  **90.7 tok/s against 78.4** (acceptance 4.06 vs 3.66) with exact copies
  preserved. GSM8K stays 94.5% (n=200).
  Knobs: `VLLM_MTP_LOOKUP_MIN` (match length to trust, default 24),
  `VLLM_MTP_LOOKUP_NMIN`/`NMAX` (kernel match window, default 4/32),
  `VLLM_MTP_LOOKUP_SEARCH` (history window, default all of it),
  `VLLM_MTP_LOOKUP_SAMPLED` (serve sampled requests too, default 0 -- see
  below).
- **Sampled traffic is the default, and it is not greedy.** Requests that omit
  sampling parameters get the model's `generation_config.json`
  (`temperature` 1.0, `top_k` 20, `top_p` 0.95); two identical requests return
  different text. The drafter then runs *probabilistically* as well, and the
  numbers differ from every greedy figure: sampled chat settles at acceptance
  **3.19-3.23** (per position 0.84 / 0.63 / 0.41 / 0.30 against greedy
  0.79 / 0.63 / 0.40 / 0.30), and a 32k verbatim-copy task reads 97.8 tok/s
  (acceptance 4.03) sampled against 98.2 greedy -- the same, because a copy is
  a high-probability path either way. At 60k the sampled copy drifts off the
  verbatim text (`copy_exact` false, 77.5 tok/s against the greedy 90.7), so
  "copy" workloads are only reliably copies when the client is greedy.
  Point-mass proposals are exact for any target but are accepted with
  probability `p(x)` instead of `min(1, p/q)`, so routing the lookup into
  sampled requests *loses*: 3.82 against the drafter's 4.03 on the 32k copy
  task. That is why the lookup is greedy-only (upstream's DFlash chain has the
  same gate) and why `VLLM_MTP_LOOKUP_SAMPLED` defaults to 0.
- **Copy/edit mode** (quoting or rewriting long documents):
  `QWEN_EXTRA_ARGS=--speculative-config '{"method":"ngram_gpu","num_speculative_tokens":7,"prompt_lookup_min":2,"prompt_lookup_max":8}'`
  replaces MTP with prompt-lookup drafting. On a 32k-token verbatim-reproduction
  task this reads **100+ tok/s against MTP's 82** (acceptance 4.4 vs 3.5); on
  ordinary chat it collapses (acceptance ~1.1, ~29 tok/s), so it is a
  copy/edit profile, not a default. The history lookup above reaches the same
  acceptance without giving up chat, so prefer it and keep this profile for
  A/B reference.
- **Prefill-heavy mode**: `VLLM_MARLIN_INPUT_DTYPE=int8` with
  `VLLM_MARLIN_INT8_INCLUDE_RE='\.mlp\.(gate_up|down)_proj'` trades about 10%
  of step time for ~8-10% faster cold prefill at 32k/64k.

Two prefill knobs are closed: `--max-num-batched-tokens 4096` **does not fit**
(cold start dies with a 110 MiB allocation against 117 MiB free, so 2048 is the
memory ceiling with a 5.5 GiB int4 pool), and `VLLM_PREFILL_ATTN=int8` (the
upstream int8-QK prefill attention) measures 54.4 s against 54.2 s at 64k and
151.5 s against 151.2 s at 128k -- no effect, matching upstream's own +0.4%.
The same int8 path is inert in the attention-dominated regime that cached
continuations live in: appending a 16k tail to a 32k/48k cache, or a 32k tail
to a 64k cache, moves by under 0.2 s (25.73/29.28/69.13 s against
25.63/29.17/68.99 s).

**Interactive latency is the tail's attention over the whole context.** With
prefix caching warm, appending tokens to a long conversation costs the tail at
a rate that falls with context (measured with 8-token replies):

| prompt | cached | tail | TTFT | tail rate |
| --- | --- | --- | --- | --- |
| 32k cold | 0 | 32k | 40.4 s | 792 tok/s |
| 48k | 32k | 16k | 25.6 s | 624 tok/s |
| 64k | 48k | 16k | 29.2 s | 549 tok/s |
| 96k | 64k | 32k | 69.0 s | 464 tok/s |
| 248k cached (lifecycle) | 246k | 2k | 8.5 s | ~240 tok/s |

So the 8.5 s cached turn at 248k is not a cache problem: it is the 2k tail
scoring against 248k keys, at the same rate a cold prefill of that size runs.
The lever is a long-context prefill attention kernel (long-q tiles and int8
scores), not scheduling.

**Night run (realistic text, deep context).** A 5.5-hour soak of the deployed
runtime with `--text-file` prompts at 4k/16k/64k: 683 requests, 0 errors,
0 Xid, decode means 108.4 / 100.2 / 77.9 tok/s, acceptance 3.76, and the
lifecycle check passed 5/5 (cold 248k 683 s, cached 8.5 s, recompute correct).
Morning gates on the same process: GSM8K 94.5% (n=200), tool-call roundtrip
fine, GPU 37 C idle. On a *realistic* continuation prompt (wikitext) the
history lookup reaches acceptance 5.0 -- every draft accepted, 127.8 tok/s
against the ~100 tok/s the drafter alone manages -- because reproducing text
that is already in the context is exactly its case.

**Decode is at the weight-read floor.** At W4A16 the 27B target reads roughly
13-14 GiB per step, about 23-25 ms at the card's effective bandwidth, which is
the bulk of a 2k step (91 tok/s at acceptance 3.17 means ~35 ms per step).
Further decode gains therefore have to come from acceptance (more tokens per
weight read) or from compressing the weights further -- not from kernel
micro-tuning. The measured levers that remain are the variable-length draft
block for greedy copy work and sub-4-bit weights or KV.

**What the quantization costs, measured against a full-precision cache.** The
same server, same 5.5 GiB pool, KV cache at float16 instead of int4 (which buys
65k context instead of 262k, and is the only higher-precision comparison that
fits this card at all -- int8 is not a vLLM cache dtype, and 8-bit weights are
27 GB):

| KV cache | PPL en / da / all | GSM8K (n=200) |
| --- | --- | --- |
| int4 per-token-head (production, 262k) | 10.8077 / 10.938 / **10.8797** | **94.5%** |
| float16 (65k context) | 10.7653 / 10.9096 / **10.8451** | **95.5%** |

So the 4-bit cache costs +0.32% perplexity and one GSM8K point, the latter
inside the +-1.1 point binomial noise of 200 questions: not measurable beyond a
fraction of a percent. Against the model's own published tables (W4A16 ~1
IFBench point below the unquantized model), the whole quantization stack costs
about 1.3% relative -- which is why 3-bit weights or 2-bit KV would be a poor
trade rather than a free win.

**Closed performance levers on this host (measured, do not retry).** The
prefill tile port's constants were swept rather than assumed: warpN=32 does not
compile, warpN=128 is 5x slower on both the 64k and 256k shapes (register
spills break the load iterator), and `minBlocksPerSm=2` gains 3% at 64k and
nothing at depth. The shipped values were already right, and at 32 TFLOPS
effective the kernel runs at 60-70% of the sm75 fp32-accumulate ceiling, so the
tail is bound by the Cutlass template rather than by its constants. Windowing a
drafter is closed too: giving the MTP drafter a 4096-token attention window
(the depth-dependent part of its 4.5->7.7 ms chain at 64k) is ~25% slower per
step at 8k (44.9 ms against 35.8 ms) and raises an illegal memory access at 64k
(Xid 31, GPU MMU fault), because the staged int4 spec kernel indexes the block
table assuming the full-causal layout. Both were live-only experiments whose
defaults matched shipped behaviour. They are recorded here because they are the
two things a future agent is most likely to try again.

**Realistic text, not filler.** `--text-file` (wikitext-2 test, first N tokens)
on `qwen38-sm75-bench` gives the numbers a real session sees. Greedy decode,
128-token replies, acceptance in brackets:

| prompt | filler decor (repeated word) | realistic text |
| --- | --- | --- |
| 8k | 90.3 [3.25] | **104.4 [3.64]** |
| 32k | 76.1 [3.11] | **97.7 [3.85]** |
| 64k | 68.3 [3.21] | 68.3 [3.12] |
| 128k | 57.3 [3.43] | **63.8 [3.69]** |

The filler understates short and mid-context decode by 15-25% because the model
answers a wall of one repeated word with prose, which the drafter predicts
badly. Sampled (temperature 1.0 / top_k 20 / top_p 0.95) realistic text at 8k
runs 3.22 tokens per step and ~38 ms per step against greedy's 3.64 and ~35 ms,
so the user-facing penalty for sampling is about 19% at 8k, not the 45% the
filler suggested. The history lookup is exactly neutral on this text (8k 104.30
against 104.37, 32k 97.13 against 97.67, identical acceptance): it does not
fire, which is the intended do-no-harm property, and its measured benefit
stays where it was measured, on greedy verbatim copy/edit work.

That table is the vLLM 0.28.0 / V1-runner measurement. The same instrument on
the 0.29.0 V2+lookup stack reads **112.4 / 99.8 / 80.6 / 80.4 tok/s** at
8k / 32k / 64k / 128k (acceptance 3.97 / 3.97 / 3.54 / 4.10), so the table is
a floor rather than a target; the full record is in the exec plan's
“vLLM 0.29 rebase” section.

**Measurement hygiene on this host.** `qwen38-sm75-bench` and
`qwen38-sm75-soak` build their prompts from one repeated word, so they are
stable *repetition* workloads, not chat: they are the right instrument for
decode-rate and stability comparisons, and they cannot exercise the history
lookup (whose proposals come from repeats) beyond what a filler prompt allows.
Use `qwen38-sm75-copy-bench` for copy/edit drafting and
`qwen38-sm75-sample-probe` for sampled traffic (default sampling:
temperature 1.0, top_k 20, top_p 0.95, from the model's `generation_config`).
Readings taken while `tiberius-qwen38-warmup.service` is still running come out
10-15% low with depressed acceptance, and a health poll right after a restart
can answer from the *old* process: wait for the unit's MainPID to change before
measuring (see `wait_restart.sh` in the operator notes).

CLI arguments otherwise still live in `hosts/tiberius.nix`.

Cold-start validation must reach API readiness under the service memory limits:
kernel-only checks miss CUDA-graph scratch allocation. Speculative attention scratch
capacity follows configured concurrency, captured when the backend is constructed,
rather than a guessed request count.

Context validation needs an **uncached near-limit prompt**, a cached continuation,
and an **unrelated-prefix replacement**. Use a unique initial prefix, check reported
cache tokens, and verify retrieval near the beginning, middle, and end. Reserve
generation space within the total context limit. Check restart/OOM counters and
host RAM, swap, and GPU memory after the complete lifecycle; successful prefill
alone is not a pass. A replacement request alone does not prove eviction: also
force the original prefix out, require zero cached tokens on recomputation, and
compare the continuation with the earlier cached result. Exercise OMP reasoning
and a real local-file tool roundtrip
through the mutable `~/.omp/agent/config-tiberius.yml` overlay as well.

Run these load checks separately from public-safe validation and keep raw
operational output outside the repository. Keep kernel timing, streamed decode,
committed-token decode, cold/cached TTFT, and concurrent throughput separate.
An EOS-only or empty reply is a failed sample, not a fast decode result. Retain
outliers and strict-format failures; post-hoc semantic audits must not rewrite
the original quality scores. Record process identity and host memory pressure,
and distinguish cold versus warmed CUDA compilation caches.

## llama.cpp-family runtime on the Turing card

Mainline llama.cpp (`pkgs/llama-cpp-cuda.nix`, pinned b11050) and beellama.cpp
v0.4.6 (`pkgs/beellama-cuda.nix`) were measured against the vLLM fork on the
same host and 280 W limit, one runtime at a time. Decode used greedy requests
and the same prompts as the fork's bench; acceptance comes from llama-server's
`llamacpp:spec_decode_*` counters with the same `1 + accepted/drafts`
convention. `qwen38-sm75-bench-llama` measures a running llama-server the way
`qwen38-sm75-bench` measures vLLM; `--nonce` forces a cold prefill.

| workload | vLLM fork | llama.cpp MTP2 | llama.cpp MTP2 + ngram-mod |
| --- | ---: | ---: | ---: |
| filler 2k / 8k / 32k tok/s | 80 / 83 / 74 | 49 / 49 / 40 | 85 / 73 / 186 |
| wikitext 8k / 32k tok/s | 99.5 / 96.3 | 52 / 42 | 84 / 78 |
| wikitext 128k cached tok/s | 63.8 | - | 22-36 |
| cold prefill 8k / 32k tok/s | 872 / 792 | - | 688 / 596 |

Long-context sweep (unique nonce prompts, context larger than the prompt so
context shifting cannot inflate speculation; same day, greedy, wikitext):

| prompt | llama.cpp cold prefill | llama.cpp decode | vLLM cold prefill | vLLM decode |
| --- | ---: | ---: | ---: | ---: |
| 32k | 596 tok/s | 35-43 tok/s | 792 tok/s | 73.7 tok/s |
| 64k | 510 tok/s | 34-37 tok/s | 678 tok/s | 76.2 tok/s |
| 128k | 390 tok/s | 22-36 tok/s | 555 tok/s | 49.8 tok/s |
| 262k | 269 tok/s (IQ4_XS) | ~21 tok/s | 363 tok/s (248k) | ~25 tok/s (est.) |

- Prefill is 25-30 % behind at every depth; ubatch size is not the lever
  (`-ub 512/1024/2048` measured 596/605/602 tok/s at 32k). Decode stays ~2x
  behind. A unique fact near the beginning of a 128k prompt was recovered on
  both engines (llama TTFT 317 s, vLLM 236 s). ik_llama matches mainline
  prefill at 128k (386.6 vs 389.6 tok/s) but decodes only 9.8-10.5 tok/s
  there; its 8 GiB default `--cache-ram` must be bounded (`--cache-ram 1024`)
  or the 7.5 GiB host thrashes.
- 262k needs UD-IQ4_XS (14.25 GiB) with q4_0 KV at ~21 GB VRAM;
  UD-Q4_K_M fails at load (22.3 GiB of weights+KV+state against 22.5 GiB
  physical). IQ4_XS measures 269 tok/s cold prefill and ~21 tok/s decode at
  262k, with no i-quant penalty visible in prefill.
- Benchmark hygiene: a prompt that fills the configured context triggers
  context shifting, which lets the ngram drafter lock onto shifted history and
  inflate acceptance (32k filler in a 32k context reported 186 tok/s /
  acceptance 25; the same prompt in a 128k context decodes 35-43 tok/s).

A second tuning round, guided by the r/LocalLLaMA mirror on pius, added:

- **Best upstream chat config**: `--spec-type draft-mtp --spec-draft-n-max 6
  --spec-draft-p-min 0.75`, which reaches 56.0/40.3 tok/s (8k/32k wikitext)
  greedy and 40.9 tok/s sampled at acceptance 3.27 -- matching the fork's
  sampled acceptance, but still ~80 ms per step against the fork's ~38 ms.
- **ik_llama.cpp + ubergarm `MTP-IQ4_KS`** (`--merge-qkv -muge
  --ctx-checkpoints 0`, q8_0 KV) is the fastest chat engine measured: 57.7
  tok/s at 8k and 40.9 at 32k wikitext with MTP4. `--ctx-checkpoints 0` is
  mandatory for this hybrid model; the default checkpoints allocate ~150 MiB
  each and kill the 32k prefill. The build recipe is ik_llama.cpp `7cff686d`
  with `-DGGML_CUDA=ON -DGGML_CUDA_F16=ON -DCMAKE_CUDA_ARCHITECTURES=75`.
- **Greedy copy/edit is now faster than the fork**: the mainline tuned hybrid
  (`ngram-mod,draft-mtp`, `n-match 24`, `n-min 48`, `n-max 64`) reaches
  86.7/80.9 tok/s, and the ik `ngram-mod`+MTP chain **105.2 tok/s at 8k**
  against the fork's 99.5. Both collapse under production sampling (40-44
  tok/s), so they are greedy-client profiles.
- **Native q4_0 K/V dequant in the FlashAttention MMA tile loader**
  (`patches/llama-cpp-native-q4-dequant.patch`, source build on b11050) removes
  the per-layer f16 conversion that quantized caches previously paid for every
  verify pass. The CPU-reference FA suite passes 12/12 and GSM8K on the patched
  build scores **96.5% (n=200)** against the fork's published 94.5%. End to
- **Turing MMVQ tuning for batches 2-8** (`patches/llama-cpp-sm75-mmvq-batch.patch`):
  MMVQ re-loads the activation vector per (row block, column), so the L2 traffic
  scales as `ncols/rows`; `rows_per_block=4` with one warp for the k-quant and
  i-quant classes lifts the production shapes from 414-438 to 466-535 GB/s at
  n=3 and from 305-376 to 364-456 GB/s at n=5 (CPU-reference tests 36/36). This
  is what makes deeper drafts viable: at 64k context / 32k prompt, **MTP4 now
  reaches 54.4 tok/s (acceptance 4.20) against MTP2's 47.0 and the base model's
  25.3**, where before the fix MTP4 was slower than MTP2.
- **sm75 prefill attention tile fix** (`patches/llama-cpp-sm75-prefill-fa.patch`):
  on Turing the query tile is capped at `ncols1 = 32/ncols2`, so the `gqa_ratio>4`
  default (`ncols2=8`) ran prefill with a 4-row tile and re-read K/V for every
  query block. `ncols2=1` keeps the tile maximal: **+4% prefill at a 32k prompt
  (615 -> 640 tok/s) and +12% at a 128k prompt (385 -> 430 tok/s, TTFT 319 s ->
  287 s)**, decode unchanged. Prefill-shaped FA correctness cases on the
  production geometry (q=32/512, D=256, 24 Q / 4 KV heads) pass 20/20 against
  the CPU reference.
  end, the 128k-prompt MTP2 step drops 82.4 -> 75.2 ms (decode 26.6 -> 30.7
  tok/s); at a 64k prompt in a 128k context the same build measures 43.9 tok/s
  (step 64.2 ms) against the fork's 49.8 (step 58.5 ms), and the 262k IQ4_XS
  step drops 135.8 -> 114.6 ms. Prefill keeps the conversion path
  (the in-kernel dequant costs 22% at prefill-sized batches).
- The mirror's 16 GB-VRAM study independently documents MTP `n=2` as optimal
  without a confidence gate and adds the sm75 analysis that the 48 Gated
  DeltaNet layers run a sequential FP32 scan -- the likely bound on batched
  speculative verification on Turing and the reason the fork's custom sm75 GDN
  and split-KV verify kernels matter.

Measured verdict:

- **The chat gap is the draft chain.** Base steps run at the same ~465 GB/s
  (vLLM 13-14 GiB in 29 ms, llama.cpp 16.4 GiB in 35 ms). Each sequential MTP
  pass costs ~9-10 ms in llama.cpp against ~1.1 ms in the fork, because the
  fork drafts with an int4 head over a 40k draft vocabulary while llama.cpp
  re-runs a Q6_K 248k-vocabulary head every pass. MTP depth, a standalone MTP
  sidecar, UD-IQ4_XS, KVarN and beellama v0.4.6 all leave that gap intact;
  mainline is 7-10 % faster than beellama at identical acceptance.
- **DFlash2 is closed on sm75**: 3.735 tokens/step at 2k but a ~65 ms drafter
  pass in both runtimes.
- **The ngram hybrid is the win and it is sampling-dependent.** With greedy
  clients it beats the fork on repetitive work (186 vs 74 tok/s at 32k) and
  gets within 15-20 % on wikitext. Under the production sampling defaults
  (temperature 1.0, top_k 20, top_p 0.95) it collapses to 36.6 tok/s at 8k,
  matching why the fork keeps its own history lookup greedy-only. Production
  OMP samples, so this is a copy/edit or greedy-tool profile, not a chat
  default.
- **Prefill and long-context decode are ~20 % behind**, the closest part of
  the comparison.

The structural fix for chat parity is the fork's recipe: a restricted (40k)
draft head and vocabulary ported to a GGUF MTP sidecar plus a draft-vocabulary
map and a cheap draft pass in the runtime. That is a loader and spec-loop
patch, not a configuration change. The measurement campaign and the open items
live in `docs/exec-plans/active/llamacpp-parity.md`.

## Hindsight runtime (pius)

Hindsight 0.10.2 runs on pius: `pkgs/hindsight.override { withLocalOnnx = true; }`
through `modules/nixos/hindsight.nix`, configured by `profiles/nixos/hindsight.nix`.
The database is an external PostgreSQL (`hindsight` on the local socket), the
embeddings are the packaged ONNX provider, and the LLM lane is the Strata engine
on tiberius (`http://tiberius:8080/v1`, `qwen3.8-flash-next-iq3_s`, thinking
disabled, concurrency pinned to 1). `hindsight.vaz.ovh` is registered in
`services.nginx.tailscaleAuth.virtualHosts`: the app authenticates `/v1` and
`/mcp` with the tenant key, but `/metrics`, `/docs` and `/openapi.json` are
unauthenticated in-app, and the host firewall accepts 80/443 on every
interface, so the nginx gate is what keeps non-tailnet clients out.

Packaging and unit traps this deployment paid for, worth not repeating:

- `mk-python-derivation` derives `doInstallCheck` from `doCheck` and
  `installCheckPhase` from `attrs.checkPhase`. Keep `doCheck = true` and define
  no `checkPhase`, or the package's install-check smoke is silently skipped.
  The phase body must also share one base indentation, or Nix's indentation
  stripping leaves the python heredoc indented.
- The fleet default is `DefaultTimeoutStartSec=15s`/`DefaultTimeoutStopSec=15s`
  and the unit is `Type=exec`, so `TimeoutStartSec` cannot bound in-process
  migrations; `TimeoutStopSec = "30min"` is what keeps a switch landing during
  a migration from SIGKILLing it (a 0.8.2 to 0.10.2 upgrade took ~16 minutes).
- `StateDirectoryMode`/`CacheDirectoryMode` must be pinned (0700); systemd
  otherwise resets the innermost directory to 0755 on every start, overriding
  the declared modes.
- Objects left by earlier deployments can be owned by `postgres`, which fails
  the alembic chain on `CREATE OR REPLACE FUNCTION`; reassign the non-extension
  functions and types to `hindsight` first (pgvector's own objects excluded).
- `checks/hindsight.nix` carries `hindsight-deploy-config`, which asserts the
  vhost gate, the unit timeout, and the deployed bind/port/LLM wiring against
  `nixosConfigurations.pius`.

## Deploy and rebuild commands

Deploy/rebuild commands are intentionally not part of default validation. Run them only when you intend to mutate a host:

```sh
nh os test                 # trajanus local test switch, no boot entry
nh os switch               # trajanus local switch
nixos-rebuild boot --flake .#<host> --target-host root@<host>
nixos-rebuild switch --flake .#<host> --target-host root@<host>
```

Prefer `nix eval` and `nix build --dry-run --no-link` before mutating rebuilds.

## Flake source snapshot reminder

If you add a new file that is imported by the flake or checked by Nix, add it to Git before relying on `nix eval`, `nix build`, or `nix flake check`:

```sh
git add path/to/new-file
```

Untracked files are ignored by the flake source snapshot.
