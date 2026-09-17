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
- `statix check .` for 13 Nix anti-pattern checks (bool comparisons, empty lets, deprecated syntax, unquoted URIs, etc.). Four noisy checks are disabled via `statix.toml` for repo-specific conventions.
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
be changed without a rebuild. Two measured profiles:

- **Copy/edit mode** (quoting or rewriting long documents):
  `QWEN_EXTRA_ARGS=--speculative-config '{"method":"ngram_gpu","num_speculative_tokens":7,"prompt_lookup_min":2,"prompt_lookup_max":8}'`
  replaces MTP with prompt-lookup drafting. On a 32k-token verbatim-reproduction
  task this reads **100+ tok/s against MTP's 82** (acceptance 4.4 vs 3.5); on
  ordinary chat it collapses (acceptance ~1.1, ~29 tok/s), so it is a
  copy/edit profile, not a default.
- **Prefill-heavy mode**: `VLLM_MARLIN_INPUT_DTYPE=int8` with
  `VLLM_MARLIN_INT8_INCLUDE_RE='\.mlp\.(gate_up|down)_proj'` trades about 10%
  of step time for ~8-10% faster cold prefill at 32k/64k.

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
