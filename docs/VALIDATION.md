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

`tiberius-qwen38.service` is a parked fast lane (the strata engine holds the
boot slot - see the Strata section below); NInfer and its assets remain
available for manual fallback. The services conflict and their stop/start jobs
are ordered, so only one owns the GPU/API port. Temporary fallback: stop the
running engine and start `tiberius-ninfer.service`; to return, stop NInfer and
start the other lane. For a durable backend change, update the host's `wantedBy`
selection and the client's context/reasoning mapping together.

## Tiberius Strata runtime

`strata-sm75` is the boot engine on Tiberius (the 27B vLLM lane took the boot
slot on 2026-10-11 until an on-box A/B of hindsight's refresh job put the two
lanes in the same envelope - 283 s on strata against 67-617 s on the 27B, with
a richer page from strata; the 27B stays installed as the parked fast and
interactive lane). It builds upstream Strata at pin
`c3b3f503` (v0.2.11, engine 0.1.57; the previous pin `ffa80d73` is v0.2.10 /
engine 0.1.56, and the v0.2.4.2 record is `dfa3f402`, engine 0.1.49.2) with three
patches:
`tiberius.patch` (a sliding DAX register window, decode-time refill pinning with
its straddle guard), `no-web-ui.patch` (`STRATA_NO_WEB=1` turns off the bundled
web app, its pages/assets and `/settings`; the OpenAI-compatible API is
untouched) and `avx512-bw-tier.patch` (the VBMI-free AVX-512 expert tier and the
split run-time gate).  Upstream's refill is the resolve/plans pass (a window's
swaps are resolved first and issued as one batch); the patch's pin
classification (`BlobClass`), page-rounded merged span registration and
straddle guard live inside it, and upstream's `fenced_slots` / `pin_blobs_on`
blocks, the batched `cp_*` copies, `adapt_copy_h2d`, `blob_stable`,
`STRATA_DMA_BATCH` and the #2188 stream query are kept.  The overlap gate's
landing signal is upstream's D2H `cudaMemcpyAsync` into `agate.hland` when that
buffer exists (a host function otherwise), and the local copy loop takes both
arms with the plan's layer.  Upstream's serve-loop `STRATA_RAM_ADAPT` /
`ram_adapt2` block, its `dt_adapt_join` timer and the `res_checking` summary are
kept; the local refill timing folds its join time into that timer rather than
adding a second join.  `carry-1283.patch` was retired at the v0.1.42 bump: upstream
took PR #1283 (commit `a26fcbcd`, the same change).  The dense-FP16 tensor-core
change that `tiberius.patch` used to carry was retired at the v0.1.40.2 bump:
upstream 0.1.39+ has the same path natively (`bf16_path()`, #540/#655) and the
module selects it with upstream's `STRATA_BF16_TC=1` (opt-in on the RTX 20's
compute capability 7.5). Build-time greps fail the derivation if a flag or
environment variable the module sets disappears on a rebase.

At the v0.2.10 bump (2026-11-03) two hunk conflicts in `generate.cpp` were
resolved by keeping both sides: 0.2.10 added `keep_sync()` at the request-ending
pin release (upstream's drafter-upkeep wait runs first, the pins are released
after it), and the `drafted` guard's `use_mtp` was renamed `draft_on` upstream
(the refill-timing join is kept around upstream's variable). `no-web-ui.patch`
and `avx512-bw-tier.patch` applied cleanly: the 0.2.10 `expert_source` changes
(the `ArenaExpertSource` #4846 RAM fallback and the Windows standby-list
release) sit outside the `FileExpertSource` region the patch owns, and the
CMakeLists growth is new split/DFlash2 translation units and comments, not the
kernel flag lists; ggml's pin is unchanged (`3cf03257`).  What reaches this lane
from engine 0.1.56 is the Qwen penalty window counting only the reply's own
tokens (#4590; `STRATA_PENALTY_PROMPT=1` restores the old window - adopted, not
pinned) and the PLE table raising the memlock soft limit to the hard one before
locking (#4671, `kernels/ngram.cpp`).  #4677's stop-bound park fix does NOT: its
`stop_bound` definition and both call sites in `generate.cpp` sit inside
`#if defined(STRATA_USE_HIP)`, so this CUDA build has neither the behaviour nor
`STRATA_SERVE_STOP_BOUND`, and the local park/restore workaround stands.  DFlash2
(CUDA 8.6+) and the all-cards split engine (two or more cards) do not select for
this box.  New in 0.2.10's serve layer: `vram_fit.fit_start` runs on every engine
start and on CUDA its only knob is `--kv-resident`; the engine turns `--kv-grow`
off whenever a KV window is set, so a start the fitter calls short would silently
drop the module's measured elastic-KV win.  That is not hypothetical: the first
0.1.56 start (generation 97) had `fit_start` inject `--kv-resident 4096`, which
turned `--kv-grow` off and shrank the DAX window from 5.52 to 2.70 GiB, and a
restart reproduced it.  The module now pins the knob with
`user_args = [ "--kv-resident" "0" ]` (the engine's unset value, and a value the
fitter treats as the person's, so its `kv_fixed` skips the knob); generation 98
starts with `--kv-grow` and `--kv-resident 0`, logs `elastic K/V: 16384 of
262144`, and registers the 5.52 GiB window.  The fitter still prints its
`short of GPU memory` line although nothing changes.  On this lane the engine is
flat and its answers move.  Measured 2026-11-03 (production config, three
counterbalanced fresh-engine runs per arm, ab26): reads -0.2% / -1.0% / -0.1% at
4,252 / 3,477 / 26,134 tokens.  Greedy answers are bit-identical across each
arm's runs but differ between 0.1.55 and 0.1.56 on the two short cells (the
26,134 cell's 8 tokens match); the server layer matters as much as the engine -
0.1.56 with the 0.1.56 server (M1) and with the 0.2.4.2 server (B) produce
different answers.  The cause is not a single change:
`data/expert-profile.bin` is byte-identical across the packages, and 0.1.56 with
`STRATA_PENALTY_PROMPT=1` (the old window) does not reproduce 0.1.55 - it keeps
B's 4,252 answer, gives a third 3,477 answer, and differs from B on 3,477 and
26,134 - so #4590, which is live because the qwen4exp card puts
`presence_penalty 1.5` on non-thinking requests while the config pins only
temperature, and other 0.1.56 engine changes both move logits.  eval80 scores
61/80 against 59/80 on the fit-pinned MTP arm (the earlier 58/80 was the pre-pin
start, `--kv-resident 4096` with `--kv-grow` off), inside that set's binomial
noise.  The bump is taken for the
serve-layer tool-call fixes (#4701, #4663/#4700, #4751) and #4590, not for speed.
Verified 2026-11-03: the Nix fetch hash matches, the three patches apply in
order to the fetched tree (`patch -p1`) and produce a tree identical to the
rebased upstream tree, a tiberius-native build succeeds
(`/nix/store/8lzw2q057hgghz75agz0dldk7hb0gshn-strata-engine-0.1.56`), and the
built binary reports `strata 0.1.56` with the DAX window, refill-pin and SM75
series markers and the `--resident-budget-gib` / `--prefill` flags present.

Post-bump experiments (2026-11-04, engine 0.1.56).  DFlash2 runs on sm_75
(upstream's table calls it untested) and is adopted: the pack was converted here
from the pinned source and checked against its pinned SHA-256, and 3+3
counterbalanced runs against the MTP keep prompts flat (+0.3% / -1.3% / -0.1%)
while decode gains 4.8% / 4.7% / 3.9%; expert slots 7,859 against 7,762 and
eval80 58/80 against 59/80.  The model card's sampling replaced the
temperature-0 pin (eval80 58/60/59/63 over the four request-level arms, one
fit-pinned DFlash2 start, inside the set's noise); campaigns send
`temperature: 0` per request.  Of the Turing
opt-ins outside `STRATA_SM75_PERF`, `STRATA_PF_FUSED_SM75` is NOT carried: it is
inert without `STRATA_PF_FUSED` (the native pack needs `requested()`), and with
both set the reads were -2.5% / -0.9% / -0.3% with no fused-path line;
`STRATA_PA_V2T` and `STRATA_SELECT_SIMT` changed answers with no consistent win
and stay off.  The NVIDIA sm_86/sm_121 default tables never load on sm_75; their generic
switches were screened and none is carried (ADAPT_NOWAIT/LAG changed the
answers, the rest sat inside the base spread, SPEC_COST is MTP-only).  Suffix
drafting is on: `suffix_draft` defaults to 3 and the DFlash2 runs log suffix
drafts.  Wide lookup windows do NOT run: `default_lookup_max_t`
returns 0 when dflash2 is set
(`include/strata/core/lookup_default.hpp:23-30`), the deployed start passes no
`--lookup-max-t`, and there is no `--lookup-max-t 12` startup line - the "16 is
flat" measurement is the MTP-era result, not a DFlash2 one.  An explicit
`--lookup-max-t` is now a campaign arm (an explicit N also raises `--spec` to
min(N,16); the window is up to 8 tokens today).  The serve layer's
`--draft-conf 0.8` was tested against 0.5 and 0.65 (2 runs each): no consistent
read gain, mixed per-token decode, different answers - 0.8 stays.  Details and
provenance: `docs/exec-plans/active/strata-pack-restore.md`, "Post-bump
experiments", and `docs/exec-plans/active/strata-tuning-next.md` for the
pending window arms.
Deployed as generation 100 on 2026-11-04: DFlash2 on the selector pack (no MTP
layer), 7,859 expert slots, `elastic K/V: 16384 of 262144`, DAX 5.52 GiB, no
`--kv-resident` injected; the config carries no `sampling` block and two
identical creative requests returned different text.

Generation 101 (2026-11-04) is the same run config with the local
transactional-park fix in `tiberius.patch` (engine
`3qla1qfa09rsf6rqmcnnndk04hrqvb0y-strata-engine-0.1.56`): a park the physical-RAM
admission gate cannot admit now skips with "nothing evicted, N still parked" and
hands the retained-K/V donor back, instead of evicting up to `slots()` parked
conversations before the refusal. The isolated port-8099 probe (a forced refusal
under a measured mlock hog) measured the pre-fix binary "evicted 2, 0 still
parked" with the next prompt re-reading 1,745 tokens from zero, and the patched
binary "nothing evicted, 2 still parked" with 1,738 tokens restored; normal
park/restore is unchanged and six answer shas matched. The same-day round-2
config screen (routed stream, prefill chunks, `--spec 8`, `--lookup-max-t`,
k8v4, sampling card0) adopted nothing; the results are in
`docs/exec-plans/active/strata-tuning-next.md`, "Round 2 campaign results".

Generation 102 (2026-11-04) keeps the same run config and engine lineage and adds the log-only
`STRATA_DAX_TIMING` instrumentation to the DAX rotation (the two-window pipelining experiment was
measured and rejected: +1.66%/+4.13% read on 4.2k/8.3k, -5.43% on 26k, rotations 9->19 and a
deterministic 26k answer-sha drift; the timing seam is what measured it and stays default-off).
It also deploys `profiles/nixos/strata-telemetry.nix` (15 s `/metrics` scraper writing
`/persist/strata/metrics/YYYY-MM-DD.jsonl`, 14-day prune, journal warnings on decode drift, two
consecutive scrape failures, GPU >=82 C and conversation-cache eviction bursts) and the
repeated-key merges that make `scripts/validate` pass again. Engine
`/nix/store/ixssrl2q9qihzvl0xwhrp3iia9vx5fhf-strata-engine-0.1.56`, system
`/nix/store/ppprl8ix6cd49k7lp2nzijzgks8sb61z-nixos-system-tiberius-...`; service healthy, smoke
completion, 7,859 slots / elastic K/V / DFlash2 / 5.52 GiB DAX. The quality harness for
answer-changing arms is now `/data/eval320/` (320 verified items, paired McNemar, fixed-corpus
logprob/PPL gate): generation-101 baseline 186/320 and 191/320 with 19 same-stack flips (5.9%,
kappa 0.877), i.e. a ~2.8 pp net edge is detectable - eval80 remains a guardrail only.

Round 4 (2026-11-04) then screened the remaining flag families in two isolated windows and kept the
config unchanged: `STRATA_ROUTE_PRIOR=1.35` lost 6.29% (L-live) / 7.54% (P2) decode
(`STATUS=1.2`), `STRATA_ROUTE_TAIL_SKIP=8`/`9` lost 4.6-13.5% across the cells (`7` stays) - the
routing arms reran L-live onto an alternate continuation whose draft acceptance fell from 98.8% to
~84.5% - and the conversation/prompt-cache probe found the deployed settings already keeping 5/5
turn-2 prefixes at 98.5% reused tokens with no pressure refusals in the isolated window
(`--prompt-cache 3` and a 1024 MiB/3-slot cache did not beat it). The next patch is streamed
session RESTORE, designed against the pin: two passes over the session file, no format change, a
250k restore's peak host RAM drops from 3,727 MiB to ~260 MB; an adjacent bug (RESTORE never resets
the DFlash2 drafter after a rewind) is a separable two-line fix to land first. Details and evidence
pointers: `docs/exec-plans/active/strata-tuning-next.md`, "Round 4 results".

Generation 103 (2026-11-04) lands the round-5 disk-session work: streamed RESTORE (two passes over
the session file, no format change; host peak ~270 MiB instead of 3,727 MiB, so a 250k restore now
fits the 8 GB box: measured 5,240 ms, VmHWM +259 MiB, identical greedy continuation sha, 50k and
old-writer MTP-lane files restorably sha-equal, corrupt/truncated/header refused before any device
write, copy-failure seams kept) plus a pre-existing SAVE bug fixed - SAVE had never worked on the
deployed DFlash2-alone lane because it unconditionally passed `mtp.kv_state()` (an empty QsaState
without `--mtp`); SAVE/RESTORE now make the draft layer optional (`layers + (use_mtp ? 1 : 0)`;
MTP-lane files stay byte-identical, DFlash2 files are layers-only, mismatched files are refused)
and RESTORE invalidates the DFlash2 drafter before the session goes live. Engine
`/nix/store/gv3vlx7ah6f37a13wyzhrz01b2gjcn4c-strata-engine-0.1.56`, system
`/nix/store/56fx2bkqqbpq5bc7z973z288n8d9f517-...`; service healthy, smoke answered, telemetry timer
active, start line unchanged (7,859 slots / elastic K/V / DFlash2 / 5.52 GiB DAX). The round-1
"Disk sessions measured" numbers in `strata-pack-restore.md` were MTP-lane measurements and are
annotated there.

Generation 104 (2026-11-05) is a hygiene regeneration of the same patch: the four "payload ends
early" over-read guards and `conversation_file.cpp`'s final newline, accepted as round-5 follow-ups,
are restored - the delta is exactly one file (4 guard lines + newline) and no behaviour change.
Host-only tests 214/214 and 4,842 checks pass; a 2m21s isolated smoke window re-ran the 50k
SAVE/restart/streamed-RESTORE path (sha equal, 1,459.7 ms), corrupt/truncated/header refusals
(SERR invalid, same pid, next request ok) and the park spot check. Engine
`/nix/store/sz2dwc0kaw5ypf1037agwg5cigbfxly2-strata-engine-0.1.56`, system
`/nix/store/j73nq77fyzzsl79mxwyf0zjk14jms43s-...`. Experiment row 9 (VRAM reserve geometry) was
closed without a window with its rationale recorded in the plan; the external Turing-unlock project
was assessed and deliberately not attempted on this hardware
(`docs/exec-plans/active/turing-unlock-assessment.md`), and the pmem park-spill design was completed
for the next round.

Generation 106 (2026-11-05) adopts the two round-7 items. First, the host boots the volatile
nlzy/turing-unlock kernel module: `pkgs/turing-unlock` builds the upstream GPL module against the
plain nixpkgs kernel of the booted version and generates the six NVIDIA 610.43.03 firmware images at
build time from two hash-pinned artifacts (no vendor blob is committed); `profiles/nixos/turing-unlock.nix`
puts the module and firmware in the initramfs and appends `turing_unlock.targets=0000:17:00.0`.
The boot log confirms `unlock result: ss0=0x88888888 ss1=0x8 readout=0x0` / `TU102 FEAT UNLOCKED`
with driver 595.71.05 healthy and no Xid; a controlled locked-vs-unlocked A/B (same engine/config/
boot) measured prefill read -6.2 % at 26,134 tokens, -2.6 % at 8,268 and -1.0 % at 4,252 in a
controlled 200 W pair, and -5.7/-2.0/-1.1 % at the production 280 W cap, decode unchanged and answer
shas identical; the gain is in the dense/projection FP16 MMA phases. Second, the pmem park-spill
hybrid (patch `a833153c`) is included but **dormant** (no `--conversation-park-*` flags, so run
config and behaviour are unchanged); its validation proved the forced file-park write (4.5 s /
3.64 GB at 250k), a streamed restore from a parked file (5.17 s with checkpoint reuse), corrupt-park
pass-1 refusal and the RAM-park regression, but the ordinary-turn "park -> next turn restores" match
is still a follow-up before the tier can be enabled. Engine
`/nix/store/2fa52rqzh86szmfmrqwkd0lziwj2da0s-strata-engine-0.1.56`, system
`/nix/store/idsww8aa0bby7bkma43yxzmbdb6jbxa3-...`; a persistent systemd-boot
`LoaderEntryDefault` EFI variable had to be re-set with `bootctl set-default` for the generation to
take effect. See `docs/exec-plans/active/turing-unlock-assessment.md` and the round-7 section of the
plan for the full measurements, safety evidence and remaining risks.

Generation 107 (2026-11-05) enables the pmem park-spill tier after the round-8 checkpoint-match fix
(patch `1f2393f2`): a parked file now saves the deepest chain checkpoint at least 1024 tokens below
the live state, keeps the whole chain as metadata only (session format v1 untouched), and a request
that would otherwise reread the prompt from token 0 takes a file candidate. Validated in one
7-minute isolated window: 250k ordinary-turn park -> next turn restored 225,280 tokens from the
pmem file in 5,149.5 ms (19.4 s including 13,917 re-read tokens, versus the 152.6 s reread) with the
continuation sha identical to the live-path re-ask; park writes 4.48-4.50 s / ~3.636 GB each; corrupt
newest file -> pass-1 checksum refusal + clean reread with the same answer, no half-restored state;
RAM-park regression clean. Production run config adds the four `--conversation-park-*` flags
(6144 MiB / 4 slots / 4096 MiB free reserve, /optane/strata-data/parks) and an `ExecStartPre` that
pre-cleans stale `*.park` files (boot re-admission not implemented). Engine
`/nix/store/gci3izrz4djkfrby0g6mnbfsfch0ys1y-strata-engine-0.1.56`, system
`/nix/store/3i99wsnkmq3jmiy975k51l9dnmhkz2b4-...`; service healthy on both doors, telemetry active,
unlock still active from the initrd, no Xid. The persistent systemd-boot `LoaderEntryDefault` EFI
variable again pointed at the old generation and was re-set with `bootctl set-default
nixos-generation-107.conf`. Unsloth Dynamic V3.1 for Qwen3.8-Flash-Next was assessed and not adopted
(`docs/exec-plans/active/unsloth-dynamic-v31-assessment.md`): it is a GGUF quantization recipe, the
engine's packer supports i-quants but not its K-quant mixes, the lane is already ~82 GB on the
124 GB Optane, and the claimed gain is against other quants; the one plausible UD-IQ3_XXS experiment
is recorded as task-24.

Generation 108 (2026-11-05) is the round-8b engine: the CUDA port of upstream #4677 (a verify window
that would commit past an EOS inside it now commits up to the stop token; `STRATA_SERVE_STOP_BOUND=0`
still disables it) and the per-request WSTAT telemetry counters on both `/metrics` and
`/metrics/prometheus` (DAX rotations, prompt-path borrowed bytes, verify windows/rows/accepted and
windows-by-size, stop-bound clips, prompt-read seconds, prefill phase timeline when
`STRATA_PREFILL_TIMING=1`; counters only, no answer change, payload numbers-only). Validation: A/B
with the bound on/off gave identical answer shas and emitted token counts on five requests; final
telemetry window showed all nine families present and monotonic, rotations reconciled with the engine
log (17 == 17), borrow 12.29 GB, stop-bound counters reported, prefill phases emitted. Two bugs were
found and fixed before deploy: the WSTAT stash was wiped by `_parse_done`, and the legacy
`/metrics/prometheus` endpoint had not been extended (its rotations counter is now the engine's
cumulative count - per-request delta from two scrapes). The pmem park tier stayed enabled from
generation 107. Engine `/nix/store/gwhnf6mm1dx0ba84swv8mzw0zq9mvcr0-strata-engine-0.1.56`, system
`/nix/store/7nac9cgx01235ivdvh7kb7rzgjwvpx2l-...`; service healthy on both doors, telemetry active,
unlock still active from the initrd, no Xid, boot default re-set to 108.

Generation 109 (2026-11-05) switches the production pack from Qwen's GSQ-RCO IQ3_S to Unsloth
Dynamic V3.1 **UD-IQ2_XS** after the round-9 A/B (both UD variants built with
`tools/iq_pack.py --experts-bin --compat-bf16`, measured with the same eval320 protocol on an
isolated engine). UD-IQ3_XXS measured +1.4 pp eval320 quality (inside the same-stack floor, not
significant) with neutral prefill; UD-IQ2_XS measured quality parity (-0.2 pp mean, 3 passes) with
prefill read -14.8 % at 4,252 tokens, -11.5 % at 8,268, -16.3 % L-live read and +4.1 % decode, a
clean same-engine control showing -24.7 % read / +21 % decode, zero DAX host-registration fallbacks
(the 39.38 GiB expert pack's 0.82 GiB layer blobs fit the 6.00 GiB window; the old pack needed 9
windows with 2 failures per pass), and 8,898 vs 7,859 expert slots. Cost: DFlash2 L-live acceptance
falls 98 % -> 85 % (decode is still faster) and greedy answer identity changes with the pack.
Deployment: model shards under `/data/strata-models/UD-IQ2_XS`, PLE shard 3 under
`/optane/strata-data/ple/`, pack `/optane/strata-data/packs/ud-iq2_xs`; the lane config gained
`midShards`/`pleShard`/`pleFile` for 3-shard models and the native dir links all three shards. API
model name unchanged; service healthy on both doors, expert cache 8,898 slots, warm request answered,
telemetry active, no Xid, boot default re-set to 109. The old GSQ-RCO IQ3_S source GGUFs/PLE were
deleted to make room (redownloadable; old pack rebuildable from them) and the coder lane's shared PLE
is consequently missing until restored (follow-up). See `unsloth-dynamic-v31-assessment.md` and the
round-9 section of the plan for the full tables and caveats. Rollback source verified: the old
model is `ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF` IQ3_S shard 1 (54,817,524,224 B, LFS sha256
`4c1eb2ce...`) and shard 2 (28,800,138,432 B, LFS sha256 `316b46f3...`, also the old shared PLE);
the plan records the re-download + `iq_pack.py` rebuild + lane-field revert steps. The coder lane is
explicitly unavailable in the module now (assertion with the restore procedure) because its pack,
model shards and shared PLE were removed by this switch.

Generation 111 (2026-11-05) bumps the engine pin from v0.2.10 (`ffa80d73`, engine 0.1.56) to
v0.2.11 (`c3b3f503`, engine 0.1.57).  Upstream's headline changes do not select for this lane: the
K-quant MMQ prompt kernels and the 32768-token `--prefill auto` ceiling are compute capability 8.0+
only (sm_75 keeps its paths, and the module's explicit `--prefill 28160` is untouched), the
all-cards split engine / two-card prompt path / layer-split trim-and-spill walk are multi-GPU only,
the gfx12 Radeon defaults are not built here, and the FP16 weight cache selects only with batch
slots (this lane runs no `--batch`/`--parallel`).  The discrete-CUDA CPU/upload share rule (ceiling
0.95, k following the pool rate) feeds PcieAuto only, and the module's
`STRATA_PCIE_FRAC_DEFAULT=old` still keeps that refinement off
(`pcie_frac_auto = ... && !pf_old`), so the start-up probe stays at the measured
`PCIe probe: 12.2 GB/s ... -> pcie_frac 0.34`.  What DOES reach the lane is the Q5_0 expert-dot fix
(upstream `aa678f10`): the constant -16 offset now takes the sum of the QUANTIZED activations; the
deployed UD-IQ2_XS pack's expert layer 4 is the only one of 48 whose down type is Q5_0
(`native_experts.txt` d_type=6), so that layer's down projection moves toward the exact result
(upstream: whole-expert error 2.1-3.1e-2 -> 1.2e-2, the other down types' level) - an accepted answer
change.  The serve layer also takes its 0.2.11 changes (chats stored as files, a running agent turn
taken over after a reload, the 60 s stream-write timeout, the bounded console queue, a start that
stops for lack of memory retried once without a drafter, the activity lease; the metric rendering is
byte-identical, and `vram_fit` is additive only, so the `--kv-resident 0` user arg still suppresses
the injected window).

Rebase: the engine-side hunks (`expert_source.cpp`, `prefill.cpp`, all 1,314 added lines of
`generate.cpp`) applied with no fuzz, and `no-web-ui.patch` / `avx512-bw-tier.patch` applied
cleanly.  `serve/server.py` needed two "keep both" resolutions - 0.2.11's per-line progress reset in
the two engine-line wait loops (every line restarts the stop limits) beside the WSTAT parse, and
0.2.11's `if not admission_rejected:` guard (#3040) around the per-request totals with the WSTAT
aggregation block re-indented inside it - plus one ADDED hook: 0.2.11 finishes non-streaming requests
in the `finally` drain loop (the early-consumer path), and that loop consumed the WSTAT line without
parsing it.  The isolated probe found the telemetry silently absent from `/metrics` on every request
(answers unaffected; cross-checked: old serve + new engine and new serve + one request both emit it,
the probe's request shape finishes in the drain loop), so the drain loop now parses WSTAT before
DONE, like the other three readers.  The build-time greps grew from 42 to 48: the new share-gate
variables (`STRATA_PCIE_AUTO_SPLIT`/`_K_RULE`/`_SHARE_MAX`), the `!pf_old` gate that keeps PcieAuto
off, the W16 `o.batch >= 2` gate, `prefill_auto_bare`, `nv_defaults.cpp`'s `STRATA_MMQ_KQ` gate and
`vram_fit.py`'s `kv_fixed` hook.

Validation: the Nix fetch hash matches (`sha256-YTKr...`); the three patches apply in order to the
fetched tree with `patch -p1` and the patched tree is byte-identical to the regenerated rebase tree;
a tiberius-native build succeeds and reports `strata 0.1.57`; the WSTAT serve smoke test passes 4/4; the deployed build (with the drain hook) is `/nix/store/x4jdmab9180v31xc5fx725py1z9mv6l7-strata-engine-0.1.57`;
the closure diff against generation 110 is the engine alone (`strata-engine: 0.1.56 -> 0.1.57`,
+315.8 KiB).  Engine start is unchanged: 8,898 expert slots, DFlash2 `--spec 6 --draft-conf 0.8`, the
5.4-5.9 GiB DAX window, `pcie_frac 0.34`, no MMQ/FP16/split lines.  Isolated A/B on port 8099
(production stopped under the GPU lock and trap-restored; deployed 0.1.56 vs 0.1.57, same config and
pack, 5 requests each): 4,252-token read 8.60 -> 8.68 s (+0.9 %), 26,134-token read
21.78 -> 21.39 s (-1.8 %), totals 2,155 -> 2,184 tok/s prefill and 65.3 -> 68.0 tok/s decode (one
interleaved run; inside the box's ~3-5 % spread).  All four speed-cell answers differ, as expected
from the Q5_0 layer.  eval320 (frozen protocol: temperature 0, thinking off, max 96) 188/320 = 58.8 %
against the round-9 UD-IQ2_XS 0.1.56 baseline 186/320 = 58.1 %: discordance 10/320 (3.1 %), McNemar
p = 0.754, risk difference -0.62 pp [95 % CI -2.50, +1.25] - no detectable quality change.

Deployed as generation 111: engine `/nix/store/x4jdmab9180v31xc5fx725py1z9mv6l7-strata-engine-0.1.57`, system `/nix/store/gb91d6ap0z57ad397xzapx8ny50l67yc-nixos-system-tiberius-26.05.20260927.cf5e765`; service healthy on both
doors, 8,898 slots, warm completion, all nine WSTAT families present after a request, no Xid, boot
default re-set to 111.  A request in the shape that used to lose the telemetry (non-streaming,
thinking off) raised `wstat_requests` and the counters after the switch, so the drain-loop hook is
live.  Rollback: revert `pkgs/strata-sm75/default.nix` and the three patch files to the parent
commit, rebuild, `nixos-rebuild switch`; the pack, model shards and PLE are untouched.  Probe
artifacts: `/data/bump/` (`window.log`, `{new,old}-results.json`, `prom-*.txt`, `eval-new.json`,
`eval-compare.json`, and the cross-serve checks in `run_cross.sh`/`serve_probe.sh`).

Generation 112 (2026-11-09) bumps the engine pin from v0.2.11 (`c3b3f503`, engine 0.1.57) to
v0.2.12 (`146df3c4`, engine 0.1.58; the annotated tag's object is `123bad4a`, and both archives hash
identically).  The release's one change that selects for this lane is upstream PR 5120
(`f000d4a4` + `7e3fae57`), which implements natively what `avx512-bw-tier.patch` had carried since
the 0.1.4x tier: the VBMI-free 512-bit CPU path (`cpu_vbmi_ok` / `cpu_vnni_ok` / `q2_rows_512_ok` in
`expert_layout.{hpp,cpp}` and a run-time-selected VBMI-free q2 unpack in `expert.cpp`) plus every
call site that selects through it.  It makes that tier OPT-IN on a CPU without VBMI
(`STRATA_VNNI_TIER=1`, `expert_layout.cpp`) because such a CPU's 512-bit rows round differently from
the AVX-2 rows it ran before; every CPU that has VBMI answers as before.  The module therefore sets
`STRATA_VNNI_TIER = "1"` (`profiles/nixos/strata.nix`), so this box keeps the tier it has had, and
`avx512-bw-tier.patch` is SHRUNK to its compile-time half: `expert.cpp`'s two 2-bit unpacks are made
VBMI-free unconditionally with tiberius's substitute (VPERMW + VPSRLVW + VPMOVWB, byte-identical to
VPMULTISHIFTQB, layout-verified against a scalar reference), and `-mavx512vbmi` is removed from
`expert.cpp` and from `iq_avx512.cpp` + `nvfp4_avx512.cpp` in both CMakeLists, so no compiler can
emit VBMI in those objects; the gate split, gate renames, call sites and bench/parity hunks are gone
(upstreamed), and `tq_avx512.cpp` keeps its flag and `cpu_avx512_ok()`.  The same tier turns on two
new 0.2.12 kernels here: `q50_512` (Q5_0 down rows in 512-bit lanes - this pack's expert layer 4 is
its one Q5_0-down layer, `native_experts.txt` d_type=6, and the kernel checks itself bit-for-bit
against this build's ggml-cpu dot on first use) and `iq4xs512` (IQ4_XS gate/up only - the pack has no
gu type 23 on any of its 48 layers, so that kernel selects nothing here).  What does not select: the
K-quant MMQ prompt kernels and the 32768-token `--prefill auto` ceiling (compute capability 8.0+),
the split engine / two-card prompt path / layer-split walk (multi-GPU), the gfx12/gfx1151 default
tables (not this build), the `STRATA_ADAPT_FETCH` PCIe-share admission (opt-in, default 0), the exact
two-pass QSA prompt selection (`STRATA_SELECT_TWO_PASS`; sm_80+ tensor-core scorer), the IQ4 W4A8
prompt kernels (`arch_ok()` = 8.0-8.8/12.0), the calibrated DFlash2 window (opt-in), the fused
512-bit gate/up rows (`STRATA_IQ512_FUSED_MAX` defaults to 0), the file tier's honest page-cache
re-check (`STRATA_UNBUFFERED_LOAD=0` returns before it) and the all-experts-resident idle policy
(8,898 of 24,576 pairs cached).  The new Auto drafting tables and the tuned DFlash2 pack need an
`auto` drafter / a CUDA "resident" card (>= 12,000 slots): the module names
`drafting = "dflash2"` and this card caches ~6.3-8.9k slots, so nothing is re-chosen and the
stock/converted pack stays.  The serve-layer tool-call/parser fixes and the Anthropic gateway's
loaded-model fallback sit in `frontend.py`/the parser, outside the WSTAT patch's regions; 0.2.12's
request-accounting rewrite (yielded prompt legs, the admission token) added no fifth DONE path, so
all four `_parse_done` sites still parse WSTAT first.

Rebase: `tiberius.patch` needed six "keep both" resolutions, all in `generate.cpp`: 0.2.12's
`drive.d.in_flight` marks (STRATA_ADAPT_FETCH) moved into this patch's plan/copy-issuance split (one
per plan, after that plan's copy is issued); the `AdaptGate::Tick` field rename (`AdaptGate* gate` ->
`std::atomic<int32_t>* counter`, ticks initialized `{&agate.landed, layer}`) adopted while keeping the
patch's plan-indexed layer; the new `STRATA_FOLLOW` reader (measurement only, off by default) landed
exactly on the CUDA stop-bound port's comment/`#if`, so upstream's whole block is kept and the
patch's unconditional stop bound stays; and upstream's new `drive.d.fetch_log` read-back block is
kept in front of the patch's `racc.windows` counter in the second plans pass.  `serve/server.py`
applied cleanly, `expert_source.cpp`, `prefill.cpp`, the `conversation_*` files and `prometheus.py`
took every hunk with no fuzz, and `no-web-ui.patch` re-verified with no conflict.  The three patches
re-applied in order with `patch -p1` onto a pristine `146df3c4` tree reproduce the rebased tree
byte-for-byte, and all postPatch greps pass (the `cpu_avx512_vnni_ok` gate grep was replaced by a
`STRATA_VNNI_TIER` guard, because the module's tier selection now depends on that knob).

Validation: the fetch hash matches (`sha256-iMjGRmrr...`); the tiberius-native build (8m60s,
379/379 actions) reports `strata 0.1.58`, `serve/test_wstat.py` 4/4, and the closure diff against
generation 111 is the engine alone (`strata-engine: 0.1.57 -> 0.1.58`, +586.4 KiB; the regenerated
config adds `env.STRATA_VNNI_TIER = "1"` and re-points three engine store paths - the only config
delta).  The gate needed TWO isolated port-8099 windows, and the first one is kept as an honest
harness finding rather than an engine result: gate1 derived both arms from the gen-111 config, so its
new arm ran WITHOUT `STRATA_VNNI_TIER` (the engine logged "CPU expert kernels: AVX-2"); it measured
188/320 vs 188/320 eval320 with all four speed-cell answers differing, and is archived at
`/data/bump/gen112-gate1/` with a note.  Gate2 re-ran with each arm's OWN deployed config (new = the
gen-112 config with the tier, old = the gen-111 config; one interleaved new-then-old run, production
stopped 07:37:24 and restored 07:46:15 UTC on 2026-11-09): the new arm logs no "CPU expert kernels"
line (0.1.58 prints it only when the VNNI tier is absent, i.e. the tier was selected) and the
comparison is clean - all four greedy speed-cell answers bit-identical (4/4 same sha), walls
+0.2 / -0.4 / -1.4 / -0.5 % (4,252-token 8.636 vs 8.617 s; 26,134-token 21.303 vs 21.606 s), totals
2,218.9 vs 2,199.2 tok/s prefill and 68.1 vs 67.8 tok/s decode (inside the box's ~3-5 % spread),
eval320 187/320 = 58.4 % against the frozen gen-111 baseline 188/320 = 58.8 % (discordance 13/320,
McNemar p = 1.000, risk difference +0.31 pp [95 % CI -1.88, +2.50] - inside the ~9-net-item
same-stack floor, no detectable quality change), and all nine WSTAT families populated after the warm
request (rotations 13, borrow 69.48 GB, windows 213, rows 277, accepted 227, stop-bound windows/rows
4/4, prompt seconds 27.40).  Start config matched gen-111: 39 s to healthy, 8,898 expert slots,
6.00 GiB DAX window, `pcie_frac 0.34`, elastic K/V (16,384 of 262,144 cells), DFlash2 `--spec 6
--draft-conf 0.8` on the stock pack, no MMQ/FP16/split/PCIe-share/W16 lines, and q50_512's
first-use check printed nothing (its "differ" line would mean the kernel declined).  One incident is
recorded: during the tiberius-native build a `cudafe++` CUDA compile on the 7.4 GiB box drove the
kernel into global OOM and killed the production engine at 2026-11-08 10:18:09 UTC;
`Restart=on-failure` brought it back on the same 0.1.57 binary in ~87 s (no journaled request in the
window), and a rebuild on this box should cap parallelism (`--cores 8 --max-jobs 2`) because of it.

Deployed as generation 112: engine `/nix/store/xwq69054iyd2p1fzr9bxj02hd72xljfg-strata-engine-0.1.58`,
system `/nix/store/v5c0fx5s73120dv42m07rm8b2594fkm5-nixos-system-tiberius-26.05.20260927.cf5e765`
(switch 07:46:58 UTC); both doors and the engine healthy, warm completion "ready." (thinking off),
the nine WSTAT families raised by a request after the switch, 8,898 slots, 6.00 GiB DAX,
`pcie_frac 0.34`, DFlash2 stock pack, no Xid, boot default re-set to 112.  The 8090 (background) door
holds GETs while the interactive lease is active - a `/health` probe there times out during the
600 s lease after a POST and answers 200 when idle; that is the lease proxy's documented design, not
a fault.  Rollback: revert `pkgs/strata-sm75/*` and `profiles/nixos/strata.nix` to `ffa932a7` and
rebuild/switch; emergency = boot the generation-111 entry (still on the ESP and rooted).  Artifacts:
`/data/bump/gen112/` (gate2 results/logs/proms, `gen112-gate1/` with gate1 and its note, `build.log`,
the source tree, `paths.txt`, gcrooted store paths) and `/data/bump/gen111/` (the frozen 0.1.57 eval
baseline, sha256 `d57acc41...`; the gen-112 eval is `db409136...`).

A post-bump option screen on 0.1.58 (2026-11-09, three isolated port-8099 windows, production
trap-restored) measured every 0.2.12 opt-in that can select on this lane against the deployed
config: `STRATA_VNNI_TIER=0`, `STRATA_IQ512_FUSED_MAX=8` (fused gate/up rows), `STRATA_ADAPT_FETCH=1`,
`STRATA_DF2_GATE=1` (default and `STRATA_DF2_ROW_MS` 5/6), the file-tier auto decision
(`STRATA_UNBUFFERED_LOAD` deleted) and the new profiling knobs.  No option showed a gain and none was
adopted (generation 112's config is unchanged).  Findings: with the route prior's 99.2 % expert-cache
hit rate the CPU expert pool sees ~0.8 % of rows, so the AVX-512 tier, `q50_512` and the fused rows
all measure as zero (profiled pool+plan per decode window: 4.020 ms tier-on vs 4.016 ms AVX-2 on the
same request; the apparent +4 % decode for `STRATA_VNNI_TIER=0` is a draft-acceptance artifact of its
different answer stream); `STRATA_ADAPT_FETCH=1` costs 2-4 % and changes answers; `STRATA_DF2_GATE=1`
with its Mac-tuned default `row_ms` costs ~5 % (windows widen, acceptance 91 % -> ~56 %), tuned to
5-6 ms it is merely neutral; deleting `STRATA_UNBUFFERED_LOAD` changes nothing because the file-tier
buffering decision is not applied without `--resident-budget-gib` (`hostTierGib=0` -> `--mmap-experts`),
i.e. that module pin is inert on this lane; and `STRATA_VERIFY_PROFILE`/`STRATA_ROUTE_STATS` cost ~6 %
decode, so they stay off.  Evidence: `/data/bump/measure/` (and `/data/bump/gen112/measure/`); the
window breakdown is in the round-14 section of `strata-tuning-next.md`.

Generation 113 (2026-11-09) bumps the engine pin from v0.2.12 (`146df3c4`, engine 0.1.58) to
v0.2.13 (`d2f0964`, engine 0.1.59; the annotated tag's object is `fb57f747`, tagged 2026-11-09
11:12 +0100).  The release itself is mostly app/Control and Qwen4 groundwork - the per-card DFlash2
defaults (Strix Halo; Blackwell cc 12.0 with >= 48 GB), the Strix Halo Windows reserve floor, the
Intel Arc fixed-order bf16 products, the app's start time and fit label, the signed feed's model list
and the separate `strata-q4-<shape>` engines.  The changes that reach this lane: **the Q8_0
hyper-connection read is now the CUDA default for Unsloth UD files**, the launcher-env stacks moved
into the engine, the Linux expert-arena file-cache credit (#5327 / PR #5531), the serve-layer
tool-call parser selection, and a build reorganisation (backend-split CMake, vendored ggml,
configure-time model geometry).  Upstream publishes no speed claim for 0.1.59 on this card.

What selects for this lane: on Linux CUDA, 0.1.59 turns `STRATA_HC_Q8` on by itself when the native
dense GGUF carries the hyper-connection projections as Q8_0 (`generate.cpp`, guarded by
`NativeDense::gguf_carries_q8_hc()`, tensor type 8).  The deployed `UD-IQ2_XS` dense file does carry
them that way - `output_hc_*` and `blk.*.hc_{attn,ffn}_{down,up}` are type 8 in its GGUF header
(checked on tiberius 2026-11-09; shard 2 is where they live) - and 0.1.58 read the same tensors
through the dequantized-BF16 path, because only setup.py's `unsloth_default_env` ever set the
switch and this lane never ran it.  The gen-113 gate carried a third, diagnostic arm (`new0`: the
gen-113 config plus `STRATA_HC_Q8=0`) to attribute the drift.  Nothing else selects: the parallel
stack needs `o.batch >= 2` and this lane runs one slot; the GDN stack (now the engine's own
`arch_defaults.cpp` default) is the same `STRATA_GDN_TC=1` / `STRATA_GDN_CONVL2=2` pair that 0.1.58's
`serve/server.py` set as `GDN_STACK_CUDA` for this very config (no `arch` key -> qwen4exp,
backend != hip), and `STRATA_GDN_TC` is arch-gated off on sm_75 anyway; #5327 is
`ArenaExpertSource::open()` and this lane runs `--mmap-experts` (`FileExpertSource`), so it is inert
(`STRATA_ARENA_FILE_CACHE=0` is its escape); the per-card DFlash2 tables are Auto-only and this lane
names the drafter; the geometry default is `flash_next`, the shape already compiled here (upstream
reports the default Flash-Next build unchanged: CUDA SASS 3573/3573); and the removed opt-ins
(`STRATA_DF2_GATE`, `STRATA_DF2_ROW_MS`, `STRATA_MMVQ_PF/SG`, `STRATA_GR_Q32_PL`, `STRATA_METAL_*`)
are set by neither package nor module.  The module now pins `STRATA_HC_Q8 = "1"` (the adopted
default) and the GDN pair explicitly in `profiles/nixos/strata.nix`.

Rebase: all three local patches re-based with **zero hunk conflicts** - 0.2.13's changes in the files
they own (generate.cpp's geometry and engine defaults, prefill.cpp's geometry widths,
expert_source.cpp's #5327 credit, serve/server.py's parser selection and launcher-env removal) sit
outside every region they own, so only hunk offsets and `index` blobs were refreshed and the
added/removed line set is byte-identical to the v0.2.12 patches.  `avx512-bw-tier.patch` was retargeted
because 0.2.13 split the monolithic root `CMakeLists.txt` into `cmake/backends/*.cmake`: the per-TU
kernel flag lists moved verbatim to `cmake/backends/cpu.cmake`, and the patch (plus the package's
postPatch guarantees, now also mirrored for `sycl/CMakeLists.txt`) follow them;
`src/kernels/cpu/expert.cpp` is unchanged upstream and its hunks are byte-identical.  The WSTAT audit
is unchanged: `serve/server.py` still has exactly four `_parse_done` call sites and all four parse the
WSTAT line before DONE - 0.2.13 added no fifth finisher.  The patch sequence re-applies in order with
`patch -p1` to a pristine `d2f0964` tree (no fuzz, no rejects) and the package's full postPatch
catalog passes on the result; the installed `serve/test_wstat.py` passes 4/4.

Build: the derivation now uses the vendored `third_party/strata-ggml` (llama.cpp `3cf03257`, the same
pin as before) and fetches no llama.cpp; `-DSTRATA_GGML_DIR`, the separate `fetchzip` and
`llamaRevision` are gone.  The fetch hash is `sha256-ygLtDY...`; the tiberius-native build
(`--cores 8 --max-jobs 2`, 379/379 actions) reports `strata 0.1.59` and `strata --geometry` prints
`flash_next`; the installed binary is an ELF executable, the payload (`serve/`, `tools/`,
`strata_control/`, both expert profiles, `gguf_fingerprints.json`) is complete, and the engine closure
contains no llama.cpp path.  The SIGILL guard was checked on the objects inside the live build
sandbox: `expert.cpp.o` has 0 VBMI/VBMI2/IFMA instructions while carrying the VBMI-free unpack form
(980 `vpsrlvw`/`vpermw`), `iq_avx512.cpp.o` and `nvfp4_avx512.cpp.o` have 0, and `tq_avx512.cpp.o` is
compiled with `-mavx512vbmi` (the flag is kept; its gate still requires it).  The closure diff against
generation 112 is the engine plus the config-derived units and system paths
(`strata-engine: 0.1.58 -> 0.1.59`); no other package moved.

Gate (isolated port-8099 window 17:55:46-18:08:00 UTC = 12m14s production down, trap-restored;
each arm from its OWN deployed config: new = the gen-113 config with 0.1.59, old = the gen-112 config
with 0.1.58, new0 = the gen-113 config + `STRATA_HC_Q8=0`): the new arm is up in 42 s (old 39 s) with
9,140 expert slots / 14.64 GiB of VRAM against 8,898 / 14.26 GiB - the Q8_0 hyper-connection copy
(0.63 GiB, logged as `STRATA_HC_Q8=1: 0.63 GiB of Q8_0 hyper-connection projections for the verify
read`) replaces the BF16 copy and frees 0.39 GiB for the cache (+242 slots, +2.7 %).  Both arms keep
the deployed start config: 6.00 GiB DAX sliding window over the 39.38 GiB pack, `pcie_frac 0.34`,
elastic K/V 16,384 of 262,144 cells, DFlash2 stock pack `--spec 6 --draft-conf 0.8`, mmap experts, no
MMQ/FP16/split/PCIe-share lines.  Speed is unchanged inside the box's ~3-5 % spread: P1 4,252-token
fresh read 8.611 vs 8.715 s (-1.2 %), P2 26,134-token read 21.404 vs 21.342 s (+0.3 %); per-request
totals 67.3 vs 67.4 tok/s decode and 2,188.2 vs 2,189.4 tok/s prefill (the new0 arm 67.6 / 2,148.6,
also inside it).  The new arm's greedy answers differ from 0.1.58 on all four speed cells, while the
new0 arm is **bit-identical to 0.1.58 on all four** - the Q8_0 HC read is the only answer-affecting
change in the bump.  eval320 (frozen protocol: temperature 0, thinking off, max 96): new
189/320 = 59.1 % against the gen-112 baseline 187/320 = 58.4 % (discordance 10/320 = 3.1 %, McNemar
exact p = 0.754, risk difference -0.62 pp [95 % CI -2.50, +1.25]) - no detectable quality change, so
the Q8_0 read is adopted and pinned.  The nine WSTAT families were all populated after the gate cells
(rotations 13, borrow 69.48 GB, verify windows 215 / rows 209 / accepted 167, stop-bound 2/2, prefill
seconds 27.78, drafts offered 209 accepted 167).  The window needed three attempts: the first two
aborted BEFORE any engine start on path typos in the gate wrapper (`bump3.py`/`mkconfig3.py` looked
up under `/data/bump` instead of `/data/bump/gen113`); the trap restored production in ~43 s each time
and no measurement was taken from those attempts.  The 12m14s window is longer than gen-112's 8m51s
because it carried the third arm and its 346 s eval320 pass.

Deployed as generation 113: engine `/nix/store/7nk2w1ip12ir53rgaaqjyfknvh1mq2ia-strata-engine-0.1.59`,
system `/nix/store/v14n6p6nwdbn9frym4czxfrc5scvs9gr-nixos-system-tiberius-26.05.20260927.cf5e765`
(switch 18:10:39 UTC, engine ready 18:11:25).  The deployed config is the gate's new arm with the
defaults pinned explicitly (`STRATA_HC_Q8=1`, `STRATA_GDN_TC=1`, `STRATA_GDN_CONVL2=2` - the config
JSON carries all three).  Verified after the switch: both doors 200, warm completion "ready."
(thinking off), 29 `strata:*` metric families and all nine WSTAT families raised by that request
(rotations 0, borrow 13.9 GB, windows 3 / rows 3, stop-bound 1/1, prefill seconds 0.37), 9,140 expert
slots / 14.64 GiB, DFlash2 stock pack, no Xid, boot default `nixos-generation-113.conf`.  The 8090
background door keeps its documented lease behaviour.  Rollback: revert `pkgs/strata-sm75/*` and
`profiles/nixos/strata.nix` to `0822608` and rebuild/switch; emergency = boot the generation-112
entry (still on the ESP and rooted).  Artifacts: `/data/bump/gen113/` (`new3`/`old3`/`new03` results,
the three engine logs, `prom-*.txt`, `eval-new3.json`, `eval-compare3.json`, `summary3.json`,
`window3.log` plus the two aborted `window3-attempt*.log`, `bump-build-gen113.log`,
`bump-switch-gen113.log`, `paths.txt`, the source tree, gcroots); the gen-112 eval baseline is
`/data/bump/gen112/eval-new2.json`.

### Generation 114 (2026-11-16): engine pin v0.2.15 (engine 0.1.61)

Generation 114 bumps the engine pin from v0.2.13 (`d2f0964`, engine 0.1.59) to v0.2.15
(`c7757280`).  The release ships engines **0.1.60** - the v0.2.14 files, carried by absolute
url - while the v0.2.15 source tree declares **0.1.61** (upstream's post-release development
bump); the engine delta between the two tags is 146 lines of serve layer, tests and an
MSVC-only test stack option, so this from-source build reports `strata 0.1.61` with the 0.1.60
engine code plus #5979 (a declared boolean tool argument written True/False is the boolean)
and #6055 (a request arriving while the engine closes is refused, not cut off).  Upstream
publishes no speed claim for 0.1.60 on this card.

What selects for this lane: llama.cpp's MMQ prompt kernels are **off by default**
(`STRATA_MMQ=ON` is the old path), and the prompt path runs Strata's fused kernels - the new
engine prints "47 of 48 layers on the fused kernels and 1 on the int8 kernels" for chunks of
1,024 tokens or more, and the staged fused entry below that.  `STRATA_OWN_CPU_QUANT=ON` moves
the CPU expert pool's dots, activation quantizers and the `--mtp-q4` requantizer to the new
`src/quant` layer; its x86 AVX-512 tier is compiled for F/DQ/BW/VL+VNNI and no VBMI (this
Cascade Lake part's exact ISA) and is selected behind `caps()`.  A segment pool for parked
conversations' K/V and a checkpoint pool are on by default, sized from the conversation cache
(`STRATA_PARK_SEGPOOL_MIB` / `STRATA_CKPT_POOL_*` are the escapes); #5697 hands an evicted
park's freed heap back and `reply_replaced` stops parking a reply the request replaces.
Prefill gains per-thread fused state (down-rotation, FP16-down, P1A) and one DMA per K/V
array; two-socket Linux pins the engine to the graphics card's NUMA node.  The stop bound
(#4677) now runs on every backend upstream, so `tiberius.patch`'s CUDA port is **retired** -
only its WSTAT counters around upstream's `serve_hold_remaining()` call remain.  The DSV41
engine left the root build (its stale probe files and patches were removed in the
follow-up), and the image/vision stack is vendored (`third_party/strata-llama`) but not
built here.

Rebase: `tiberius.patch` needed **eight** resolutions - one in `conversation_cache.hpp`
(`evictable_bytes()` beside upstream's `drop_oldest()`/`release_free_heap()` rewrite of #5697)
and seven in `generate.cpp`: the include comment, the park-pool block (upstream's pools kept,
this patch's `ConversationParkFiles` declaration appended), the physical-RAM refusal comment
(merged), the parking condition (upstream's `reply_replaced` kept beside this patch's
`file_restore`), and the stop-bound block (upstream's call and `stop_skip` kept).  The rest of
the patch applied directly.  `no-web-ui.patch` applied cleanly.  `avx512-bw-tier.patch`
applied cleanly to `src/kernels/cpu/expert.cpp` and `cmake/backends/cpu.cmake`; its
`sycl/CMakeLists.txt` hunks were retargeted by hand (0.1.60 moved the two flag lists) and
`tq_avx512.cpp` keeps `-mavx512vbmi` in both builds.  The three patches re-apply in order to a
pristine `c7757280` tree and reproduce the resolved tree exactly (tree hash verified), and the
package's full postPatch catalog passes on the result.  The WSTAT audit holds:
`serve/server.py` has exactly four `_parse_done` call sites and all four parse WSTAT before
DONE.

Build: fetch hash `sha256-ehbQHpljUeclywp0ubGcrGG+xQ35SppRoosVWZLJiDY=`; the tiberius-native
build (`--cores 8 --max-jobs 2`) finished 367/367 actions (`buildPhase completed in 6 minutes
13 seconds`) and reports `strata 0.1.61`, `strata --geometry` = `flash_next`.  The payload is
complete (`serve/`, `tools/`, `strata_control/`, both expert profiles,
`gguf_fingerprints.json`), the output is 59 MB and its closure has no llama.cpp path.  The
SIGILL guard on the installed binary: `objdump -d` has 0 `vpmultishiftqb` / `vpermt2b` /
`vdpbf16ps` instructions and 1,537 `vpsrlvw`/`vpermw` (the VBMI-free expert unpack), and the
installed `serve/test_wstat.py` passes 4/4.  The package names the gate's two build-level
choices explicitly (`-DSTRATA_MMQ=OFF`, `-DSTRATA_OWN_CPU_QUANT=ON`), so a later upstream
default flip cannot move the lane.

Gate (isolated port-8099 window 14:34:12-14:48:44 UTC = 14m32s production down, trap-restored
and health-checked; both arms from the SAME deployed gen-113 config JSON, only the engine store
path swapped): old = 0.1.59, new = 0.1.61.  Up in 42 s vs 45 s; 9,156 expert slots / 14.66 GiB
of VRAM vs 9,140 / 14.64 GiB.  Speed is inside the box's spread and slightly the new arm's
way: P1 4,252-token fresh read 8.46 vs 8.55 s (-1.1 %), P2 26,134-token read 21.13 vs 21.47 s
(-1.6 %); request totals decode 68.5 vs 66.9 tok/s and prefill 2,237.1 vs 2,187.7.  The greedy
answers differ on all four speed cells (a new engine, as expected); eval320 (frozen protocol)
is **192/320 = 60.0 % new against 193/320 = 60.3 % old**, discordant b=5/c=4, exact McNemar
**p = 1.000**, risk difference +0.31 pp [95 % CI -1.56, +2.19] - no detectable quality change.
Parks: 4.3k tokens 143 vs 148 ms; 26k 431 vs 319 ms (the one move against the bump - the
segment pool is 512 MiB of the 2,048 MiB cache, so a 26k park is mostly fresh pages; not
gate-blocking, upstream's default is kept).  29 `strata:*` families, the stop-bound and
verify counters populated; no MMQ line, the fused-kernel path instead.

The gate arm's binary and the pinned derivation's binary are **not bit-identical** (same
source, patches and flags; `.text`/`.rodata` byte-identical, the delta is confined to the CUDA
fatbin container, +480 bytes); the only recorded build difference is parallelism (the gate
build ran `-j24`, the pinned one `-j8`), so the build is not bit-reproducible.  The deployed
binary was therefore behaviour-checked rather than trusted: with the gate harness's warm-up
request first, as the harness always does, the deployed engine returns the gate's exact P1
answer sha (`23009150...`, 87 tokens, prompt 4,252 tokens).  Without that warm-up the same
binary answers deterministically from a cold first request (86 tokens) - a state effect, not a
binary difference.

Deployed as generation 114 (2026-11-16 14:58:02): engine
`/nix/store/2nwms0p9ixlw64s8asjj41glnd6rj4a5-strata-engine-0.1.61`, system
`/nix/store/xkj3b227iv9i31y8vzg48cmq7np7162k-nixos-system-tiberius-26.05.20260927.cf5e765`.
The switch's closure diff is the engine alone (`strata-engine: 0.1.59 -> 0.1.61`, -47.7 MiB);
no other package moved.  Verified after the switch: 8080 and 8081 health 200, warm completion
"ready.", 9,156 expert slots / 14.66 GiB, the park file tier on, 29 `strata:*` families with
all nine WSTAT series raised by the probe requests (rotations 6, borrow 27.73 GB, verify
windows 53 / rows 44 / accepted 37, stop bound 2/2, prefill 7.316 s, drafts 44/37), and no
Xid.

Follow-up screen (2026-11-16, isolated port-8099 window 15:14-15:27 UTC, arms on the deployed
0.1.61 engine): the park segment pool at its default sat 512 MiB resident / 454 MiB idle after
the 4.3k park (57 MiB live), and its bytes count against the 2,048 MiB conversation cache;
parks measured 90-147 ms (4.3k) and 328 ms (26k).  With `STRATA_PARK_SEGPOOL_MIB=0` the same
parks took 104-164 ms and 360 ms - 32 ms more on the 26k park, against 512 MiB returned to the
image budget - so the pool is pinned **0** in the module.  The `--prefill` re-screen (28160 vs
56320 vs 22528) was flat: P1 8.40-8.54 s and P2 20.71-21.15 s across every arm (the 56320 arm
clamping to the same chunk), so 28160 stays.  The stale `dsv41-*-probe.nix` files and their
patches were deleted (the DSV41 build left 0.1.60).  Deployed as generation 115 (2026-11-16
15:28:24): system `/nix/store/v8l7igkphhcahf7dbjb78hyapn40k0hq-nixos-system-tiberius-26.05.20260927.cf5e765`;
the diff to generation 114 is the engine's config JSON alone (-38.5 KiB), and the unit's config
carries `STRATA_PARK_SEGPOOL_MIB=0`.  Health 200 on 8080/8081, warm completion, 9,156 slots,
park tier on.

Rollback: revert `pkgs/strata-sm75/*` to the commit before `6729ee8` (and
`profiles/nixos/strata.nix` to before `1035a63` for the pool pin) and rebuild/switch;
emergency = boot the generation-113 entry (still on the ESP and rooted).  Artifacts:
`/data/bump/gen114/` (scripts), `/data/bump/{old4,new4}-results.json`, `eval-{old,new}4.json`,
`summary4.json`, `eval-compare4.json`, `window4.log`, `prom-*.txt`, the follow-up screen
(`window5b.log`, `{dep,seg0,pf56,pf22}5-results.json`, `screen5.json`), and the deployed-binary
probe lines in `/persist/strata/strata-iq3-s.log`.

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

Re-confirmed on the 0.1.61 deployment (2026-11-18, live `/metrics` and direct
requests, no restart): 5,877 / 39,857 / 156,872-token new prompts read in
8.2 / 26.5 / 94.8 s; a repeated prompt reused 5,870 / 39,850 / 156,865 tokens
in 89 / 100 / 78 ms.  A 4K repeat at 99.7 % expert-cache hit and 51 MB read
still took 8.5 s, so the fixed term is the DAX pack-stream copy wait (2,626 ms
of the 7,111 ms GPU timeline at 4,245 tok in the 2026-11-04 breakdown), not
expert-cache misses.  No flag removed it: the 2026-11-04 campaign rejected
`STRATA_PREFILL_ROUTED_STREAM=1` (+32.6..+87.9 % read on >=1,024-token cells)
and the `--prefill 8192/16384` / `--no-prefill-borrow` arms.  The larger
6,784 MiB DAX window was then tried (2026-11-18, three counterbalanced
fresh-engine runs): P1/P2/P27 reads +1.43 / +1.25 / +0.53 %, rotations 20 vs
20, and the P1/P2 answer sha changed; rejected.  The DAX route is closed on
this box; the 4K floor is structural and the conversation cache is the
practical lever.

v0.1.42's two new CUDA decode defaults were measured the same way and split.
The rank-7 verify tail skip (`STRATA_ROUTE_TAIL_SKIP=7`, upstream's default,
set explicitly so a future default flip cannot move the box) won big here:
decode 21.30 -> 29.50 tok/s (+38.5%) on the 4292-token cell and
26.03 -> 34.50 (+32.5%) on the 3517 cell, with the prompt read within noise
and pool + plan per decode window down 104.8 -> 63.0 / 85.6 -> 50.4 ms
(-40% / -41%).  It is adopted, accepting upstream's answer drift (mean
KL 0.0058, top-1 agreement 97.7%, PPL x1.011; HumanEval/reasoning within their
own noise).  The CPU-measured PCIe share lost instead: it moved the share
0.34 -> 0.50 on every run that used it ("the CPU pool takes ~328 us per missed
expert (6.2 GB/s of expert bytes), the link 12.2-12.3 GB/s") and decode fell
21.30 -> 19.80 (-7.0%) and 26.03 -> 24.27 (-6.8%) with the tail skip off (and
-0.3% / -4.9% on top of it), so the module pins
`STRATA_PCIE_FRAC_DEFAULT=old` (the start-up rule the ab8 campaign already
kept as control).  The campaign ran twice, on a trajanus-built engine
(`/data/ab10*`) and on the tiberius-native build that ships (`/data/ab10n*`),
with the same conclusions to within 0.1-0.3%; the numbers above are the native
run's.  Evidence: `/data/ab10*` + `/data/ab10n*` (driver `/data/ab10.py`,
`/data/ab10-arms.sh`, per-run engine logs and `/metrics`).

The pair was re-validated on 2026-11-16 against the agent-lane concern (a report of
"faster but dumber" long tool-calling turns after an update).  Two counterbalanced
port-8099 windows ran the voxel-pagoda tool trace and eval320 with the adaptive tier on:
the thread's failure did not reproduce (8/8 trace turns valid, no truncations; the
pagoda task is not a quality discriminator - 0 of 3 artifacts usable, three different
failure modes), and greedy eval320 is **194/320 with the deployed pins against 193/320
with both knobs off** (8 A-only / 7 B-only, 305/320 items agree, exact McNemar
p = 1.0000, ~4x wall).  The 18.75 pp eval80 gap the campaign saw under `--adapt-swaps 0`
is a feature-by-placement interaction, not a flag effect: pinning the tier freezes
`ROUTE_PRIOR`'s premise.  The deployed pins stay, and `--adapt-swaps` must not be pinned
in production.  The completed campaign plan is kept as a private note (not checked in,
per `docs/PLANS.md`); artifacts `/data/qg/` on tiberius.

v0.1.43's adaptive overlap (the tier's copies landing while the next verify
window runs) was measured before adopting.  On Linux CUDA upstream turns it on
by default, but it is skipped in the resident RAM mode this box runs unless
`STRATA_ADAPT_OVERLAP_RESIDENT=1`, so the deployed default already has it off;
the opt-in lost here: 25.6 / 30.3 tok/s against 27.2 / 35.2 on the P1
(4292-token) / P2 (3517-token) decode cells - 3 counterbalanced runs per arm,
per-arm spread <=0.1 tok/s - and it streamed more file bytes - so the module
pins `STRATA_ADAPT_OVERLAP=0` (upstream's escape hatch, explicit so a future
default flip cannot move the box).  The bump's answer drift was run to ground:
v0.1.43's resident-tier arena is 1 MiB larger at the same `--resident-budget-gib
1.0` (1022 -> 1023 MiB), so 1 MiB less VRAM is free when the expert cache opens
and the profile walk packs one expert pair fewer at the same budget (6285 vs
6286 slots, both reporting 11.93 GiB; `--expert-cache N` on a native pack is a
budget of N x largest-blob bytes, NOT a slot count - a request above what fits
is a no-op).  On this box's tight 6 GiB-window cache that one pair moves the
residency margin, and the text follows the residency (the same binary answers
differently at 6281 vs 6285 slots).  At a budget both versions fit
(`--expert-cache 4400`: 5743 slots and 11171 MiB on both) the engines are
byte-identical on all three cells - the 4292-token and 3517-token reads and a
short question - 3 runs per arm, with identical content shas, streamed bytes of
42148 / 32327 / 10924 MB, hit rates 82.3 / 86.3 / 64.6% and decode within 0.1%
(25.03/31.23/21.77 vs 25.00/31.27/21.77 tok/s) - so the drift is the sizing
margin alone, not the engine.  Evidence: `/data/ab11*` (auto cache, 3 arms x 3
runs), `/data/ab12*` + `/data/ab16*` (budgets above what fits, 2 arms),
`/data/ab17*` (the matched-budget parity run), `/data/ab13*`-`ab15*`
(flag-semantics probes; drivers `/data/ab11.py`-`ab17.py`, per-run engine logs
and `/metrics`).

The 0.2.x line also changed two serve defaults that would move this lane without
touching a performance knob.  Since 0.1.45 a request that names no sampling keys
gets the model card's values (thinking 1.0/0.95, instruct 0.7/0.8) where 0.1.43
was greedy; the module no longer pins `sampling.temperature` - the model-card
sampling was adopted on 2026-11-04 (the gen-100 config has no `sampling` block:
non-thinking 0.7 / top-p 0.8 / top-k 20 / presence_penalty 1.5, thinking
1.0 / 0.95 / 20), and campaigns that need determinism send `temperature: 0` per
request (`profiles/nixos/strata.nix:340-350`).  Since 0.2.3 (#3493) `--serve`
sizes a parked-conversation cache from the free RAM when `--conversation-cache-mib`
is absent (up to 8 GiB, floor ~2.5 GiB); the module pins the cache explicitly -
`--conversation-cache-mib 2048`, 4 slots, a 1,536-token floor, a 384 MiB min-free
and a 512 park gain, sized against this box's RAM pressure, not the 0.1.43
default (`profiles/nixos/strata.nix:225-234`).  The live gen-100 config matches
the module; the old pins were checked on the 0.1.49.2 build (`/data/ab24*`).

The 0.1.45 RTX 20 kernel series (`STRATA_SM75_PERF=1`) is adopted.  It is bitwise
here: every arm in the campaign returned the same answer sha on all four cells.
Measured 2026-10-24 on the 0.1.49.2 build, 3 runs with the series against 5
controls, counterbalanced (A-B-B-A), fresh engine per run, medians:

| cell | prompt tokens | prompt read | decode |
|---|---:|---:|---:|
| D4K | 4,252 | +0.5% | +2.3% (78 generated) |
| P20K | 19,407 | +5.6% | +2.5% (8 generated) |
| P27K | 26,134 | +7.3% | +4.0% (8 generated) |
| D29K | 27,720 | +8.0% | +3.5% (88 generated) |

The other Turing-era switches were screened and not adopted: `STRATA_QSA_ROWS`,
`STRATA_EXPDEC` and `STRATA_DEQUANT_WIDE` added nothing on top of the series
(the four-switch stack read slightly below the series alone), and
`STRATA_ATTN_DAILY=1` with `STRATA_ATTN_V3=0` was within noise.  The 0.1.49.2
engine itself is +1.8..2.1% on the prompt read over 0.1.43 at the same pins;
D4K/P20K/P27K answers are byte-identical to 0.1.43, while D29K diverges after the
new engine's auto cache opens with 6,268 slots against 6,281 (the residency
margin documented above).  Evidence: `/data/ab24*` (driver `/data/ab24.py`,
`/data/ab24-arms.sh`, per-run engine logs and `/metrics`).

The engine build must happen ON tiberius. ggml compiles with `-march=native`
(the package clears `NIX_ENFORCE_NO_NATIVE`), and the host's `nix.conf` lists
pius (an AVX2-only i5-8400) and trajanus (Zen 4) as builders, so a plain build
dispatches this derivation and the binary carries the BUILDER's codegen.
Measured 2026-10-11: a pius build of the same drv differs from a trajanus one
in 50,132,344 bytes, with two instruction classes in play.  The engine's own
AVX-512 expert kernels (`expert.cpp`) are compiled without `-mavx512vbmi` and
selected at run time by `cpu_avx512_vnni_ok()` = F+DQ+BW+VL+VNNI (the
`avx512-bw-tier.patch` gate split), so this Cascade Lake part runs them; the
trellis TU (`tq_avx512.cpp`) keeps `-mavx512vbmi` and the original
`cpu_avx512_ok()` gate (which still requires VBMI), because weakening the shared
gate would select a VBMI kernel on a VBMI-less CPU.  The split was measured on
2026-10-12 (ab18 campaign, 3 counterbalanced runs per arm): the expert tier is
~5% cheaper in CPU `pool+plan` per decode window, with prefill and the Optane
reads unchanged.  ggml's own `*_generic`
fallback dots and `ggml_vec_dot_bf16`, by contrast, carry the build host's
`-march=native` with no run-time gate: the trajanus build has 262 instructions
the Xeon Gold 6246 cannot execute (260 `vpermt2b` / AVX512-VBMI in the
q3_K/q5_0/q5_1/q6_K generic kernels and 2 `vdpbf16ps` / AVX512-BF16 in
`ggml_vec_dot_bf16`), the native build has 0, and the deployed v0.1.41 (also
trajanus) has the same 262.  They have not been reached in this config (16
campaign runs plus two days of production, all clean), but they are one
fallback kernel away from a SIGILL for another quant type or lane.
`preferLocalBuild = true` in `pkgs/strata-sm75` keeps the dispatch on the host
that runs the engine (verified on the 2026-10-11 deploy: the box built it
locally, 44 compilers, no `ssh-ng` line, and the result has 0 of the
builder-only set); `-DGGML_NATIVE=OFF` is the portable fallback for any
non-tiberius consumer.

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

### Generation 116 (2026-11-20): engine pin v0.2.16 (engine 0.1.62)

Generation 116 bumps the engine pin from v0.2.15 (`c7757280`, engine 0.1.61) to v0.2.16
(`64524fb9`, engine 0.1.62).  This release restructures the repository: the engine tree moved
from the root into `engine/`, and the Python side the service runs (`serve/`, `strata_control/`,
`tools/`, `data/`) into `terminal/` (`app/` is the desktop app and is not built).  The
derivation keeps the repository root as `sourceRoot`, configures cmake with
`cmakeDir = ../engine`, installs the serve layer from `terminal/serve`, and the three patches
now carry `a/engine/...` and `a/terminal/...` paths; the installed
`$out/share/strata/{serve,strata_control,tools,data}` layout is unchanged.

What selects for this lane:

- llama.cpp's MMQ prompt kernels are **gone from the tree** (upstream: "MMQ comparison builds
  come from the v0.2.15 tag"): every CUDA build compiles Strata's own prompt kernels
  (`strata_pf_own`) and the FP16 path, so there is no `-DSTRATA_MMQ` option left.  The deployed
  0.1.61 ran with it OFF already, so this lane's prompt kernels are the ones it had; the
  package now names only `-DSTRATA_OWN_CPU_QUANT=ON` of the gate's two build-level choices.
- A release engine **links no ggml at all**: with tests off and the Strata quant pool on,
  `engine/CMakeLists.txt` skips `strata_ggml_configure_root()` ("Strata: no ggml in this build
  (own CPU pool, no MMQ, tests off)").  `engine/third_party/strata-ggml` is still carried and its
  llama.cpp pin is still asserted, but nothing from it is compiled into the service binary -
  which retires the builder-codegen hazard class the 0.1.41 build carried in ggml's
  `-march=native` generic kernels.
- **Three of this package's hunks are superseded** and dropped: session SAVE / RESTORE / capture
  now take a nullable draft (`generate.cpp`'s `session_draft`, `const QsaState*` in the
  conversation API), which is exactly the no-MTP overload this patch had added;
  `ConversationCache::evictable_bytes()` arrives upstream (#2253) as the same pre-check; and the
  DNS-rebinding host/origin helpers this patch carried were upstreamed into
  `serve/server_parts` (only `web_disabled()` and the 404 gate remain this package's).
- One new upstream default is pinned **off**: `--conversation-spill-mib 0`.  0.2.16 adds a
  conversation-cache SSD tier - a park the RAM tier evicts, or a capture the RAM floor refuses,
  becomes a session file under `<dataDir>/conversation-spill`, budget a quarter of free space
  capped at 32 GiB, i.e. ~12.5 GiB on this box's 50 GiB free /optane.  The pmem park tier
  already covers the refusal path this lane measured (round 7/8), so the tier waits for its own
  campaign.

Rebase: `tiberius.patch` needed 21 content resolutions (12 in `generate.cpp`, 4 in
`conversation_state.cpp`, 2 in `conversation_snapshot.hpp`, 3 in `terminal/serve/server.py`)
plus three file-location ones (the park-file header, its test and `test_wstat.py` are new files
added into directories upstream renamed, so they land at the new paths).  The `generate.cpp`
resolutions are the park pools, the serve setup (upstream's `ConversationSpill` beside this
patch's park-file tier), the physical-RAM refusal message, the #879 nan flush, the slot-read
block, and the borrow/take guards, which now carry BOTH upstream's `!from_ssd` and this patch's
`!file_restore`.  `no-web-ui.patch` shared the two `server.py` resolutions;
`avx512-bw-tier.patch` applied cleanly (the flag lists in `cmake/backends/cpu.cmake` and
`expert.cpp`'s hunks are unchanged upstream, the sycl lists moved with the tree).  Two
duplicate-definition build failures were fixed during the rebase (the patch's own
`evictable_bytes()` and a doubled `n_parked` in the #879 flush) - both are upstream code this
patch no longer needs.

Build: fetch hash `sha256-g6TO9zC2jt41B5oADYrypIrXpb73/QzXmqjUuzBe9E4=`; the tiberius-native
build (`--cores 8 --max-jobs 2`) finished 321/321 actions (`buildPhase completed in 4 minutes
11 seconds`) and reports `strata 0.1.62`, `strata --geometry` = `flash_next`.  The payload is
complete (`serve/`, `tools/`, `strata_control/`, both expert profiles,
`gguf_fingerprints.json`), the serve modules import with the module's python env, and
`serve/test_wstat.py` passes 4/4.  The output is 60 MB and its closure has no llama.cpp or ggml
path.  The SIGILL guard on the installed binary: `objdump -d` has 0 `vpmultishiftqb` /
`vpermt2b` / `vdpbf16ps`, and exactly the deployed 0.1.61's AVX-512 counts (490 `vpsrlvw`,
1,047 `vpermw`, 848 `vpdpbusd`) - the CPU expert tier is the same VBMI-free code.

Gate (isolated port-8099, GPU lock, production stopped only inside the windows and
trap-restored + health-checked; both arms from the SAME deployed gen-115 config JSON, only the
engine store path swapped, the new arm with the SSD tier pinned off).  The first window
(07:48:53-08:04:31) measured the old arm and then aborted when the new engine's store path had
been garbage-collected; the new arm and the tier probe ran in a second window
(08:09:56-08:19:38).  Up in 45 s both arms.  Fresh reads are +2.4..+3.3% on the new engine (P1
8.64 vs 8.37 s, P2 21.10 vs 20.59 s), prefill flat (2,293 vs 2,285 tok/s).  The per-request
decode rate reads ~6% lower on the arm totals (65.8 vs 70.1 tok/s) but over different answer
lengths (414 vs 392 tokens), so this protocol cannot separate that from content noise - the
previous gates carry the same caveat.  eval320 (frozen protocol) is **197/320 = 61.6% new
against 188/320 = 58.8% old**, discordant b=3 (old-only) / c=12 (new-only), risk difference
-2.81 pp [95% CI -5.31, -0.62], exact McNemar **p = 0.035** - the new engine is better on this
set, not worse.  The answers differ on all four speed cells (a new engine, as expected).
`/metrics` has 35 `strata:*` families on the new arm against 29 on the old: #6081's
conversation-cache families (parked, parks, restores, evictions, refused by reason) join, and
all nine WSTAT series stay populated (rotations 13, borrow 69.3 GB, verify windows 246 / rows
217 / accepted 168, stop bound 1/1, prefill 26.51 s).

A blind spot this gate shares with the previous bumps: it exercises 4.2k and 26k prompts only,
so it cannot see the elastic K/V's window ceiling.  On 0.1.62 the K/V may take expert-cache
slots only below the prompt path's loan, which is `lend_slots(chunk)` - at `--prefill 28160`
the loan is 8,057 of the 9,156 slots and the K/V tops out at 180,224 of the 262,144 cells,
failing "the K/V could not grow to 188416 cells" on a 178,985-token conversation (found
2026-11-20 after this deploy).  A future bump's gate should include a >180k-token cell, or the
ceiling moves silently.

SSD tier probe (0.1.62 with the tier left ON, `--conversation-cache-mib 768`, 26k-token
conversations): the tier comes up (`SSD tier in /optane/strata-data/conversation-spill/<pid>-
<hash>, up to 13,784 MiB`); a 512 MiB RAM cache skipped every park ("snapshot 579 MiB exceeds
available budget"), which is how the first probe came back empty-handed; at 768 MiB the third
conversation evicts the first park and the spill folder grows, and the repeat of that prompt
restores **26,121 of 26,128 tokens in 257 ms (0.41 s wall) against 19.4 s fresh**.  The tier is
pinned off for the deploy; its value on this box (and its answer-neutrality) needs its own
campaign.

Deployed as generation 116 (2026-11-20 08:25:46 WET): engine
`/nix/store/8ssk1gii0df05mc03jpqdlprz95lywzj-strata-engine-0.1.62`, system
`/nix/store/als39zsf5ilgj2095bskflrp37zgmqx2-nixos-system-tiberius-26.05.20260927.cf5e765`
(`--target-host` and `--build-host` both tiberius, so the gate-tested binary is the deployed
one).  The switch's closure diff to generation 115 is the engine (`0.1.61 -> 0.1.62`, +1.2 MiB),
34.8 KiB of config source, and the lane JSON's rename (`strata-general.json` in,
`strata-iq3-s.json` out - the model-name change of commit `9740d5e`, which this deploy carried);
no other package moved.  Verified after the switch: both doors healthy (`8080` through the
lease proxy, `8081` the engine's own), the model `qwen3.8-flash-next-unsloth-ud-iq2_xs` loaded,
a warm completion "ready.", 9,156 expert slots / 14.66 GiB of VRAM, the park file tier on, the
engine's command line carrying `--conversation-spill-mib 0` and no "SSD tier in ..." start-up
line, 34 `strata:*` metric lines with the WSTAT series populated (verify windows 3, stop bound
1), and no Xid.

The switch itself exited 4 on `tiberius-strata-lease.service`: it cannot bind :8080 because the
transient `lease-cors` service holds the front door (the drift recorded on 2026-11-17 - the
declared unit had been stopped and a `systemd-run` proxy with the uncommitted CORS diff serves
it).  The declared unit was stopped again after the switch to return it to its pre-deploy state;
the transient proxy answers :8080 and health is 200.  This is unaffected by the engine bump and
still wants the CORS diff committed (or retired) one way or the other.

Rollback: `nixos-rebuild switch --rollback` on tiberius (generation 115: engine
`/nix/store/2nwms0p9ixlw64s8asjj41glnd6rj4a5-strata-engine-0.1.61`, system
`/nix/store/v8l7igkphhcahf7dbjb78hyapn40k0hq-nixos-system-tiberius-26.05.20260927.cf5e765`),
or boot that generation's entry.  The strata bump alone reverts with
`git revert 25ec55d` plus a rebuild; the spill pin lives in `profiles/nixos/strata.nix`.  Artifacts:
`/data/bump/gen116/` (scripts), `/data/bump/{old6,new6}-results.json`, `eval-{old,new}6.json`,
`eval-compare6.json`, `summary6.json`, `spill6-results.json`, `window6.log`,
`prom-{old,new}6.txt`, `/data/bump/logs/`.

### Generation 118 (2026-11-22): SSD tier on, lease proxy declared, tuned DFlash2 rejected

Generation 118 changes one thing in the running system: the lane's config JSON gains
`--conversation-spill-mib 8192`.  The engine store path is unchanged (`8ssk1gii...`, 0.1.62), and
so is the lease proxy (`l1c2f...`) - the CORS support it was already running had been built from
the working tree at generation 117 and is now committed (`f133ce8`), so a clean-tree build keeps
it.  The transient `lease-cors` unit (the Nov-16 workaround) was stopped and the declared
`tiberius-strata-lease` serves :8080 again, enabled at boot; the switch restarts it cleanly.

Follow-up measurements behind this generation (artifacts in `/data/bump/camp11/`, scripts and
`analysis11.json`; one isolated port-8099 window, production trap-restored):

- **The gen-116 gate's decode -6% is refuted.**  Same deployed config, both engines, 3 x L-live
  (the round-10 structured cell, 768 generated each - the cell's 40-object array exceeds the cap,
  so no `ignore_eos` is needed and every run is directly comparable): 0.1.61 **110.7** against
  0.1.62 **111.0 tok/s** on the warm runs (+0.3%), and the draft acceptance is identical, **85.3 %
  (1827/2142) on both**.  The gate's number came from comparing totals over different answer
  lengths; there is no decode regression to chase.
- **Upstream's tuned DFlash2 drafter is a regression on this pack and is rejected.**
  `qwen3.8-flash-next-dflash2.strata1.q4_0-selq4.pack` (the feed's 340 MB file, sha256
  `4df2e5ab...`, fetched from the v0.2.16 release) measured against the stock pack on the same
  engine and config: acceptance **78.2 %** at `--draft-conf 0.8` and **77.3 %** at 0.7 against
  the stock pack's **85.3 %**, and decode **104.7 / 104.2** against **111.0 tok/s** (-5.7 / -6.1 %).
  The tuned weights were fine-tuned on 4-bit targets' outputs; this lane serves a ~2-bit pack
  (UD-IQ2_XS), which is the distance the tuned pack does not close - the same 98 -> 85 acceptance
  drop the UD switch measured.  With the round-10 spec sweep already bounding the alternative
  (`--spec 4` recovers acceptance to 91.6 % but costs 1.2 % decode), **99 % acceptance is not
  reachable with the available drafters on this pack**; the stock pack at `--spec 6
  --draft-conf 0.8` stays.
- **The conversation SSD tier is enabled at a bounded 8,192 MiB.**  In the same window, five
  distinct 26k conversations fill the 2,048 MiB RAM park cache and evict: with the tier off the
  repeat of the first conversation is a full **20.14 s** re-read; with it on the engine writes the
  evicted park in the background (579 MiB, 0.7-4.7 s) and the repeat **restores 26,121 tokens in
  152 ms** - **0.85 s wall**.  This lane's two days on gen 116/117 logged **442 park events, 409
  of them with evictions** (up to 172 in one event) and 98 restores (median 15,453 tokens, max
  180,445), against only 3 physical-RAM refusals - evictions, not refusals, are the failure mode,
  and the pmem park tier already covers the refusals.  The cap keeps the disk cost bounded (the
  upstream default here would be ~13.8 GiB of /optane's 54 GiB free; one 180k park is ~4 GiB).
  Rollback is the one flag: `--conversation-spill-mib 0`.

Deployed as generation 118 (2026-11-22 17:46:35): system
`/nix/store/a0annahhch237svrk645ach32fp6ilrv-nixos-system-tiberius-26.05.20260927.cf5e765`; the
closure diff to generation 117 is `strata-general.json` (`jp7prmi0` -> `wr99rh14`) alone.  Verified
after the switch: the engine's command line carries `--conversation-spill-mib 8192`, the start-up
line reports `SSD tier in /optane/strata-data/conversation-spill/<pid>-<hash>, up to 8192 MiB`, the
old campaign folder was removed as an ended engine, both doors are 200 (8080 through the declared
lease proxy), the preflight from `http://localhost:5173` answers 204 with
`Access-Control-Allow-Origin` and a non-loopback origin gets no CORS header, and there is no Xid.

Rollback: `nixos-rebuild switch --rollback` on tiberius (generation 117), or set
`--conversation-spill-mib 0` in `profiles/nixos/strata.nix` and rebuild.  The tuned pack stays at
`/optane/strata-data/dflash2/*.strata1.*.pack` (unused; 340 MB) for a future re-test.

### Generation 121 (2026-11-23): DFlash2 draft-skip live; TU102 unlock dropped

Two config changes from generation 120; the engine build (0.1.63) and the model are untouched.
Build host: tiberius (`--build-host root@tiberius`); the Mac's store was at 832 MB free, so
nothing was built locally.

- **`STRATA_DF2_LOOKUP_SKIP=8` is live** (`profiles/nixos/strata.nix`). The flag skips the DFlash2
  draft round when the suffix finds a match of 8+ tokens and lets the draft policy take the
  prompt-lookup window directly; the draft is deferred to the next round, not lost. Measured on the
  isolated 8099 engine (rounds 17b/17c): copy 111.2 -> 112.95 tok/s cold and 123.3 -> 125.55 warm
  (+1.6 / +1.8 %), ~1 ms less per decode round (4,603 -> 4,527 ms for 512 tokens at the same 76-77
  rounds), copy text byte-identical (sha `b112adf5...`); edit inconclusive inside its spread, prose
  inert (no 8+ match fires). Adopted under the owner's 2026-11-23 cumulative-wins policy: the +4 %
  bar is a default, not a veto, for env-only arms that leave the affected text byte-identical.
- **The TU102 unlock is removed from tiberius** (`hosts/tiberius.nix`; the profile and
  `pkgs/turing-unlock` stay in the tree, unused). Its firmware derivation fetched
  `nvidia-utils-610.43.03-1-x86_64_v3.pkg.tar.zst` from `archive.cachyos.org`, and that URL now
  returns a 988-byte landing page (pinned `sha256-4X58ku7...`, the page hashes to
  `sha256-LUOVBOes...`), so no from-scratch build could produce it - this was the blocker for the
  skip deploy. The kernel was already stock nixpkgs (the CachyOS kernel arms were removed after
  <=0.6 %), so the unlock was the host's only CachyOS dependency; with the URL rot, the
  single-boot evidence and the power/thermal risk, it is dropped rather than re-sourced. Cost: the
  measured gain was prefill read -5.7 % at 26,134 tokens / -2.0 % at 8,268 / -1.1 % at 4,252,
  decode unchanged. The six generated images are kept on the host at
  `/data/turing-unlock-firmware-610.43.03/` (7 MB) for a future re-source from NVIDIA's `.run`.

Deployed as generation 121 (2026-11-23 10:45): system
`/nix/store/vaxiv0mynv2cgjvbdl2l1b3nsa7ssm1b-nixos-system-tiberius-26.05.20260927.cf5e765`;
config JSON `89ic7xvn...` carries the flag. Verified after the switch: health 200 on 8080/8081,
engine 0.1.63 with DFlash2 alone (`--spec 6 --draft-conf 0.8`), 9,156 expert slots, the engine's
`/proc/<pid>/environ` carries `STRATA_DF2_LOOKUP_SKIP=8`, `/run/current-system/kernel-params` has
no `turing_unlock` line, `/run/current-system/firmware/turing-unlock` is gone, no Xid, GPU 21,408
MiB / 36 C. The running kernel and its cmdline are the pre-switch ones until the next reboot (the
loaded unlock module goes with that reboot); the new boot entry carries neither.

Rollback: `nixos-rebuild switch --rollback` on tiberius (generation 120), or revert `a3a9968`
(skip) / `cf2be56` (unlock) and rebuild. Artifacts: `/tmp/deploy-120.log` (local, not committed);
the campaign data in `/data/ab53-*.log`.

### Generation 122 (2026-11-23): TU102 unlock re-enabled from NVIDIA's installer

The unlock came back the same day it was dropped, with a durable source.
`pkgs/turing-unlock` now fetches NVIDIA's own `NVIDIA-Linux-x86_64-610.43.03.run`
(sha256 `45e2d4c1...`), takes `gsp_tu10x.bin` from it (same hash the CachyOS package
supplied), builds `v67` with upstream's pure `generate_v67.build_payload()`, and keeps the
kernel-module-source step for the four boot assets; the derivation checks all six outputs
against the hashes the earlier generations ran and fails on any drift. The host import and
`hardware.turingUnlock.enable = true;` are restored in `hosts/tiberius.nix`. The archive
(tiberius `/data/archive/`, pius `/persist/archive/` and `/root/archive/`) and
`pkgs/turing-unlock/regenerate-firmware.sh` remain the fallback if NVIDIA's URLs move;
all six regenerate from NVIDIA alone (cold-tested 2026-11-23).

Deployed as generation 122 (2026-11-23 11:05): system
`/nix/store/mylas9im2g5gqp34vjc6kfpf8vrpcwyx-nixos-system-tiberius-26.05.20260927.cf5e765`,
built on tiberius (`--build-host`). Booted one-shot into 122 with generation 121 as the
fallback, then set 122 as the default. Verified after the reboot: `turing_unlock` loaded
(kernel tainted out-of-tree), all six firmware assets requested and read with `error=0`
(`booter_load_tu102.bin` 59,224 B, `v67` 64,000 B, `gsp_tu10x.bin` 29,352,832 B, and the
rest), the module logged `TU102 FEAT UNLOCKED` (`ss0=0x88888888 ss1=0x8`, `unlock result`
matches), 9,156 expert slots / 21,408 MiB, `STRATA_DF2_LOOKUP_SKIP=8` still in the engine's
environment, health 200, no Xid.

Rollback: boot generation 121 (the fallback entry until this boot; 122 is now the default),
or set `hardware.turingUnlock.enable = false;` and rebuild (the unlock is volatile and a
power cycle re-locks either way).

### DeepSeek-V4.1-Flash IQ1_M: not runnable on this fleet (checked 2026-10-24)

The smallest official set (`ist-das-1.75bpw`, ISTA-DASLab/DeepSeek-V4.1-Flash-1017-GSQ-RCO-GGUF)
needs a **239.30 GB download** (120.72 GB IQ1_M backbone + 110.60 GB shared Engram + 7.98 GB
DSpark drafter + metadata) and roughly the same on disk after packing; setup adds 6 GB of
headroom, so ~245 GB must be free in one folder. It also needs **>=34 GB RAM** for the tight
IQ1_M RAM store (46 GB measured on an RTX 3060, 64 GB comfortable), a **>=8 GB (12 GB measured)
GPU**, and the separate `strata-dsv41` 0.1.49.2 engine. That engine's signed CUDA packages
contain `sm_86`/`sm_120`/`compute_120` only (RTX 30/40/50; HIP covers gfx1200/gfx1201); the
source can be built for `sm_75` with `-DSTRATA_BUILD_DSV41=ON`, but that path is outside the
validated matrix and does not remove the disk or RAM blockers.

| Host | Hardware | Verdict | Binding constraint |
|---|---|---|---|
| tiberius | RTX 2080 Ti 22 GB (sm_75), 7.4 GB RAM, 35 GB largest free filesystem | **no** | disk (239 GB needed), then RAM (7.4 vs 34 GB); official package has no sm_75 |
| trajanus | 30 GB RAM, no NVIDIA GPU | **no** | no supported GPU; RAM below the 34 GB tight mode |
| pius | 62 GB RAM, no NVIDIA GPU | **no** | no supported GPU |
| Mac | Apple silicon | **no** | no DeepSeek engine on macOS |

The only locally runnable DeepSeek artifacts are random-tensor kernel/plumbing tests
(`ds4_gg_bench`, `ds4_iq_test`, `ds4_gguf_test`); they do not load the model and do not cover
IQ1_M. **Conclusion: blocked on hardware; do not download the 239 GB set.** A runnable
configuration needs one host with >=245 GB free on an NVMe filesystem, >=34-46 GB RAM and an
RTX 30/40/50 or RDNA4 card, or a rented/remote host.

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
hide a rising trend and the fans cannot oscillate at the trip points. A sensor
read is retried up to three times; a chassis that stays unreadable fails safe
to the BMC for that tick without latching, so a transient IPMI hiccup cannot
pin the loud curve for the rest of a session.

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

The runtime is pinned to the fork's `turing` branch re-exported against **vLLM
0.31.0** (fork `ed0422a`, 2026-10-11): upstream's 49-patch 3090 series and the
21-patch Turing series apply to a pristine `v0.31.0` at `--fuzz 0`, and
`prepare-runtime.py` applies the same stack to the wheel and asserts the
49-patch upstream series. The fork's port record — the one retired patch
(upstream 0.31 now owns the Mamba checkpoint alignment) and the marlin `g_idx`
re-signing — is `docs/turing-0.31-port.md` in the fork.

**Validated on this pin (2026-10-11, tiberius).** All five packaged checks
(`attention`, `prefill`, `prefix`, `gdn`, `downloads`) and the three kernel
suites (`test_turing_gdn`, `test_turing_prefill`, `test_turing_marlin`) pass;
the first pass found and fixed the retired shared-memory guard and the missing
`runai-model-streamer` pin in `requirements.lock`. Decode on the same
instrument, production procedure: **121.8-122.1 / 98.1-110.0 / 95.1-95.5 /
80.5-81.1 tok/s** at 2k / 8k / 32k / 64k (acceptance 4.10 / 3.54-3.85 / 3.66 /
3.46). The spread inside the 8k cell is the **pass**, not the pin: the first
pass at a cell reads lower than a repeat in the same boot (98.1 [3.541], then
110.0 [3.848]), and that reproduces with the unit's warmup service running or
stopped — the two runs agree to the digit in acceptance and within 1% in decode,
so the warmup service is not the depressor. The same-day A/B (same client, file,
flags and procedure) puts this pin at or above the 0.29 runtime in every cell and
pass state: 2k 117.6 against 109.7, 8k 113.0/110.9 against 97.0/95.8 (acceptance
3.85 against 3.40), copy 3.59 on both. The 0.29 column in the tables below is the
2026-09-24 session, and its 8k 112.4 / 3.97 sits at the top of the warm-pass
range. Quality is unchanged (PPL en 10.8097 / da 10.942; GSM8K 96.0% n=200). The
128k / 253k decode cells and the prefill tails below still come from the 0.29.0
runs.

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
on tiberius (`http://tiberius:8080/v1`, thinking disabled, concurrency pinned to
1; the 27B vLLM lane stays installed as the parked fast/interactive lane). The
model is `qwen3.8-flash-next-iq3_s` there: the repository has named it
`qwen3.8-flash-next-unsloth-ud-iq2_xs` since generation 116, but pius still runs
the old string until its next switch (110 commits behind on 2026-11-23). The
reflect wall clock is raised to 1800 s: a
mental-model refresh runs the reflect pipeline (tool-call iterations over a
9.5-28K-token prompt) and the 300 s default killed every refresh since
2026-07-03 - on both engines. With it raised, both engines complete the job in
the same envelope (283 s on strata, 67-617 s on the 27B), so the 2026-10-11
engine swap was not what fixed hindsight - the clock was. Mental-model pages
regrow across refreshes (2.8 -> 3.2 -> 5.4 -> 6.6 KB over one afternoon) and
each model's `max_tokens` (600-800 here) acts as a soft page-length directive,
not a hard cap. The refresh task fails intermittently with
`ReflectNoAnswerError: Reflect's done tool returned no answer` - seen on both
engines and with thinking on or off (2026-10-11: 21:46 on the 27B with
refresh-path reasoning, iteration 7 / 14 tool calls; 22:39 on strata with the
deployed thinking-off config, iteration 10 / 9 tool calls), roughly one run in
four that afternoon, and the task's own retry (up to 4 attempts) completed both
times - so a single failure is expected flakiness, not a config verdict.
Refresh-path reasoning
(`HINDSIGHT_API_MENTAL_MODEL_REFRESH_LLM_EXTRA_BODY` with `enable_thinking:
true`) therefore remains untested rather than disproven; the proven levers for
deeper pages are the page budget (or a different refresh-path model - the block
has its own provider/model/base_url knobs).
`hindsight.vaz.ovh` is registered in
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
