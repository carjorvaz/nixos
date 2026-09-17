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

**Decode is at the weight-read floor.** At W4A16 the 27B target reads roughly
13-14 GiB per step, about 23-25 ms at the card's effective bandwidth, which is
the bulk of a 2k step (91 tok/s at acceptance 3.17 means ~35 ms per step).
Further decode gains therefore have to come from acceptance (more tokens per
weight read) or from compressing the weights further -- not from kernel
micro-tuning. The measured levers that remain are the variable-length draft
block for greedy copy work and sub-4-bit weights or KV.

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
