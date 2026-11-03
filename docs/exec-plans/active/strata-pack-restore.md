# strata on tiberius: the pack's missing experts.bin, and the measured plateau

Status: **fixed and measured 2026-10-28.** The Qwen3.8-Flash-Next lane on the
Optane is back to its historical numbers; the 20x regression was a missing file
in the prepared pack, not an engine or configuration problem.

## Symptom

The service started on 2026-10-27 18:03 and answered, but at
**1 tok/s decode and 28 tok/s prefill** (a 4,252-token prompt read in 151 s, a
21-token chat reply in 89 s). The engine's own log blamed I/O:

```
stage 0: 16 windows; per window: wait for the GPU 16.0 ms, pool + plan 5338.0 ms,
         host staging 0.7 ms, commit 2.0 ms
file tier I/O this request: the OS read 60843.4 MB from storage (4877434 major faults)
         for 30173.9 MB of expert reads; page cache held 770.9 MB at the read, not 30476.1 MB
decode waited 117548.6 ms in 15036 fetches
```

60 GB of device reads for 30 GB of requested expert bytes, at ~690 MB/s
aggregate: the read path was a SATA SSD, not the Optane. `nvidia-smi` showed
healthy idle clocks (300/405 MHz P8, 1905/6800 MHz under load), 475 MiB VRAM
free, and no Xid.

## Root cause

`/optane/strata-data/packs/iq3_s` was rebuilt on 2026-10-27 11:36 **without
`--experts-bin`**: it held `dense.bin`, `index.txt`, `native_experts.txt` and
`tokenizer/`, but no `experts.bin`. `tools/iq_pack.py` says so in its docstring:

> `experts.bin` — optional (`--experts-bin`) ... the engine otherwise reads the
> experts from the GGUF itself

and the engine implements exactly that: a native pack without `experts.bin`
maps the model's GGUF shards instead (`generate.cpp`: "CS-T: a native pack
without experts.bin maps the model's GGUF shards instead (native_experts.txt's
spans)"). Shard 1 is 54.8 GB and lives on `/data` (ZFS, SATA): **407 MB/s
measured** with `dd iflag=direct`, against the Optane's 6.8 GB/s random-blob
rate. Nothing fails, nothing warns: the startup log says "native pack: ...
experts" and the I/O line says "the GGUF in place".

The Oct 27 rebuild was a space decision: with the DeepSeek lane occupying the
Optane, the pack was re-prepared without the 46.84 GiB blob. The DeepSeek data
was reclaimed later, but the pack was not rebuilt.

## Fix

Run the engine's own packer on the box (no Nix build, no re-download; it reads
the two GGUF shards that were kept and writes the missing blob):

```
cd /nix/store/<engine>/share/strata
python3 tools/iq_pack.py \
  --gguf /data/strata-models/IQ3_S/Qwen3.8-Flash-Next-GSQ-RCO-IQ3_S-00001-of-00002.gguf \
  --out  /optane/strata-data/packs/iq3_s \
  --experts-bin
```

Measured: 46.84 GiB written in **under five minutes** (2026-10-28 12:53-12:57,
`experts.bin`, plus
`experts.bin.src.json` so the next run can reuse it), `/optane` from 87 GB to
40 GB free. Restart the unit afterwards.

## Measured after the fix (0.1.49.2 / v0.2.4.2, production config)

Same cells as the ab11/ab24 campaigns (real corpus, greedy, thinking off):

| cell | before | after |
| --- | --- | --- |
| 4,252-token prompt read | 151 s (28 tok/s) | **9.3 s (456 tok/s)** |
| 4,252-token prompt, 78 gen | ~1 tok/s | **22.1 tok/s, cache hit 77.7%** |
| 3,477-token prompt read | 150 s (23 tok/s) | **9.4 s (369 tok/s)** |
| 3,477-token prompt, 59 gen | 1.5 tok/s | **28.1 tok/s, hit 87.9%** |
| 27,720-token prompt read | ~28 tok/s | **1,153 tok/s** |
| 1,247-token answer (real client) | - | **28.3 tok/s sustained** |

That is the historical plateau: the ab24 campaign (2026-10-24, same package)
measured 1,112 / 1,169 / 1,153 tok/s at 19.4k / 26.1k / 27.7k and 21.8 tok/s on
the 4.2k cell; ab11 (0.1.43) measured 21.3-29.6 tok/s on the same shapes.

## Configuration screen on the restored pack (0.1.49.2, one pass each)

| arm | 4.2k read | 4.2k decode | hit | 3.5k decode | hit |
| --- | --- | --- | --- | --- | --- |
| production (int8 KV, `--prefill 28160`) | 456 tok/s | 22.1 | 77.7% | 28.1 | 87.9% |
| `--vram-reserve-mib 768` | 467 | 22.0 | 77.5% | 24.9 | 87.9% |
| `--prefill auto` | 465 | 22.4 | 77.5% | 27.8 | 88.0% |
| `--prefill 14336` | 441 | 22.4 | 77.5% | 27.8 | 88.0% |
| `--kv k8v4` | 457 | **23.4** | **79.7%** | 27.1 | 88.6% |

Nothing here moves the needle beyond noise. The engine's "prompt chunk of 28160
tokens lends 6037 cache slots ... prompts can read ~3x slower" warning is real
in principle but does not show on these cells: `--prefill auto` and `14336`
measure the same prompt-read time as 28160. `k8v4` is the only candidate
(+6% decode on the short cell, +2 points of hit rate); it trades the int8 V
cache for Q4_0-rotated, so it is kept as an A/B arm, not adopted from one run.

## Prevention

`profiles/nixos/strata.nix` now fails the start when
`<dataDir>/packs/<lane>/experts.bin` is missing (`test -f` in `ExecStartPre`).
The fallback is silent and 20x slower, so a missing pack must be a start
failure with this document as the pointer, not a service that answers.

## v0.2.7 (engine 0.1.52) and the residency-biased router: 2.5x decode

The pin was bumped to v0.2.7 (5e8a4cca) - see `pkgs/strata-sm75/default.nix` for
the rebase notes (three-way merge of the DAX-window and refill-pin patches into
upstream's rewritten adaptive-refill plans pass; `no-web-ui.patch` merged past
the new `/tool-media/` route).  Built on tiberius from the local flake; the
pre-patch gates and a full request set run before deployment.

Same cells, engine 0.1.52, one fresh engine per arm, real corpus, greedy, thinking
off (read / decode tok/s; the generated counts are 78/97, 63/81 and 8):

| cell | base | + `STRATA_ROUTE_PRIOR=1.5` |
| --- | --- | --- |
| 4,252-token prompt | 460 / 22.4 (hit 77.8%) | 474 / **56.1** (hit 98.1%) |
| 3,477-token prompt | 382 / 26.8 (hit 87.2%) | 382 / **62.4** (hit 98.4%) |
| 26,134-token prompt | 1,254 / 29.6 (hit 91.8%) | 1,266 / **77.8** (hit 99.2%) |

For reference, 0.1.49.2 on the same 4,252-token cell (ab24, 2026-10-24, the
production config) measured 463 tok/s and 21.8 tok/s decode at a 77.7% hit rate,
and the best this box ever recorded before today was 29.5 / 34.5 tok/s (ab11,
0.1.43, 4.2k / 3.5k cells with 256 generated).  The 26,134-token read is
unchanged across 0.1.52 and the router (1,254 vs 1,266, ab24's 1,266).

`STRATA_ROUTE_PRIOR=1.5` is upstream 0.2.7's residency-biased router: after the
router picks the top-k, the choice is re-picked with a logit bonus for experts
already resident, so a decode window's misses collapse (hit 77.8 -> 98.1%).
Upstream enables it by default only on a discrete CUDA card of 13 GiB or less;
this 22 GiB card runs the same streamed-expert regime and is forced on in the
module.  It changes which experts run, so answers differ from the off arm by
construction; `STRATA_ROUTE_PRIOR=0` (or `STRATA_DEFAULTS=026`) is the escape.

`k8v4` KV on top of it measured 54.8 / 63.8 tok/s (4.2k / 3.5k cells) - within
noise of `int8` - so the int8 KV (the better-quality V side) stays.

### Quality gates for the router (same window)

- Needle-in-a-haystack, 27.8k-token haystack from the real corpus, code word at
  10 / 50 / 90% depth: **3/3 found in both arms** (base and routed), answers
  verbatim.
- 10 exact-answer arithmetic questions, greedy: **10/10 off the router, 9/10
  with it** (the miss is a two-line word problem answered 31 for 29).  Ten
  questions is a small sample - it is consistent with upstream's own 80-task
  run on the 12 GB card, which saw no copy or code errors and agent-task pass
  rates inside the run-to-run spread.  This is the price of the router; the
  escape hatch is `STRATA_ROUTE_PRIOR=0`.
- The 26.1k prompt read is unchanged (1,266 vs 1,254 tok/s): the router does not
  cost prompt throughput.

Deployed 2026-10-28 13:53 (system generation 83, engine 0.1.52, rebuilt after the
patch-header correction): the live service reads the 4,252 / 3,477-token prompts
in 9.05 / 9.11 s and decodes **55.7 / 62.0 tok/s** (hit 98.1 / 98.4%), and the
18-token warmup prompt reads in 414 ms against 876 ms before.  For reference, the
historical maximum on this box was 29.5 / 34.5 tok/s (ab11, 0.1.43).

### What the prompt cache reuses (corrected 2026-10-30)

A chat turn reuses its turn boundary.  With a ~1.9k system block and a short user
turn, the first request reads 2,399 tokens in 8.9 s; the next turn (same
conversation, one assistant reply and a new user sentence appended) reports
`2,392 reused + 51 read in 557 ms` and decodes at 51 tok/s.  At depth the same
holds: a 239,195-token chat read in 190.5 s (1,255 tok/s) and its next turn
reused **239,188** tokens and read 52 in **547 ms** (0.1.54, lambda 1.2, no other
client).  `--prompt-cache-root 1024` changes nothing (the same 2,392 reused at
either root): the mark a chat turn mounts is the turn-boundary checkpoint
(`turn_at`, the last `<|im_start|>`), which is deeper than the root, so the root
size - and `--prompt-cache-tail` / `--prompt-cache-spread` - have nothing to add
for this shape.  The root only decides what a prompt with no turn boundary can
reuse.  None of the three is carried.

What does not reuse is text appended *inside the same user message*: a
2,127-token prompt extended by one sentence re-reads all 2,138 tokens in 8.5 s
(`reused 0`).  Reuse is prefix matching at a checkpoint (a turn boundary, or a
complete 28,160-token prefill chunk: a 239k prompt reused 225,280 of 239,241 when
the append was inside the message), and an in-message append shares no whole
checkpoint with its predecessor.  An attempt to checkpoint the prompt's end
(n-1) - the state a raw-prompt continuation needs - was built and measured: it
helps only that shape and costs a 118 MB host checkpoint per short request, so it
was reverted before the deploy.

### Two clients on one engine: an uncached request wipes the chain

Measured on the live service 2026-10-30: our turn 1 (2,399 tokens, 2
checkpoints), then another client's uncached prompt (23,642 and 27,125 tokens,
2,038 and 1,427 generated at ~84 tok/s), then our turn 2 (2,444) - `reused 0`,
9.5 s again.  The same two turns on the same engine with no interleaved request
reuse 2,392.  At 250k the live turn 2 reused 0 and re-read 188 s.

The main session keeps ONE checkpoint chain (`checks`), pruned to the current
request's prefix, and a request that resumes from 0 clears it, root included
(`generate.cpp:14531-14544` in v0.2.8).  So on a busy engine the interactive
reuse above is best-effort.

**What fixes it, measured: `--kv-grow` plus parked conversations.**  A
checkpoint is the recurrent state only, and "the KV cache itself is positional
and stays where it is", so a parked conversation can be restored only when the
K/V moves with it.  `--kv-grow` maps only the cells a request reaches and lets
the parked image be restored by token identity (`take_reuse_for` refuses another
conversation's bytes).  kv-grow is refused while `--resident-budget-gib` is
present (that flag sets `resident_cpu_experts`), so the 1 GiB host tier went;
the elastic K/V then buys +27% expert slots (7,766 against 6,123) and, on the
same harness cells at lambda 1.2:

| cell | before | after |
| --- | --- | --- |
| 4,252 read / decode / hit | 457.7 tok/s / 49.2 / 96.8% | 497.8 / 57.3 / 98.2% |
| 3,477 read / decode / hit | 384.3 / 51.6 / 98.0% | 408.4 / 64.5 / 98.6% |
| 26,134 read / decode / hit | 1,162.3 / 52.5 / 98.1% | 1,245.5 / 49.3 / 99.1% |

Live on generation 88 the same cells read 490.2 / 59.0 / 99.2% and 404.9 / 62.5 /
99.2%.  The isolation probe (one 2.4k conversation around a 19.4k foreign
request):

| | parking off | parking on |
| --- | --- | --- |
| turn 2 reused / read | 0 of 2,443 / 9,325 ms | 2,392 / 1,238 ms |

**What it does not fix.**  A 250k conversation needs a measured 4,276 MiB
snapshot: refused against the 2,048 MiB budget
("skip parking (snapshot 4276 MiB exceeds available budget)") and the 250k turn
still re-reads 164 s when something interleaves.  Under RAM pressure a
background conversation can itself be refused on the floor and overwrite ours:
of five live probes on the deployed flags two kept the prefix (2,358 and 2,388
of 2,410 tokens, 1,183 and 380 ms) and three lost it.  The failure is a RAM-floor
refusal of the *background* snapshot, not an eviction ("skip parking (physical
RAM admission; need 621 MiB plus 384 MiB floor, 842 MiB available; evicted 0)"),
so it tracks how much RAM the box has free when the foreign request arrives.  So this is
best-effort isolation up to ~50k-token conversations; a busy box still wants the
two clients serialised.

The snapshot cost solves exactly as a line: 17,282 B per token plus ~349 MB
(3 x ~116 MB of checkpoint/live state), so 391 MB at 2,433 tokens (K/V only 42
MB of it), 652 MB at 19,496 and 4,276 MiB at 239,240 (K/V 92% of it).

**The box (SMBIOS, 2026-11-01).**  8 GB of DRAM in one RDIMM (Micron
18ASF1G72PZ, 2400 MT/s) plus a 128 GB Intel Optane DCPMM (NMA1XXD128GPS) in
persistent mode as `/dev/pmem0` - 11 of 12 DIMM slots are free, the array
supports 2 TB.  Every RAM-limited path above is therefore an 8 GB-of-DRAM
problem, not a hardware limit: +32 GB of DDR4 (one RDIMM) exceeds the ~4.1 GiB
that a 250k disk restore needs and the 4,276 MiB a 250k park needs; one module in
each of the six channels (P0_MC0/C1 _DIM_CH_A0/B0/C0/D0/E0/F0) fills the board's
bandwidth, A1 being channel A's second slot.  Upstream is
`github.com/Niko1221/Strata` (the URL `serve/server.py` itself cites for #481);
on 2026-11-01 `main` was `c62d5e3a` = v0.2.9, and on 2026-11-03 the pin moved to
`ffa80d73` = v0.2.10 (engine 0.1.56, built and smoke-tested, not yet deployed).
0.2.10's #4677 (a parked conversation refused on the next turn, ~6% of the
prompt re-read) is HIP-only: `stop_bound` and both call sites in `generate.cpp`
sit inside `#if defined(STRATA_USE_HIP)`, so this CUDA build has no upstream
park fix and the conclusion stands - a park/restore fix has to be written here.
The unpacked trees under `/persist/strata-src` are a convenience, not a
fallback.

**Lease front end (deployed 2026-11-01, generation 94).**  `pkgs/strata-lease-proxy.py`
now fronts the loopback engine (`127.0.0.1:8081`) with two doors - `:8080`
interactive, `:8090` background - and treats every request from pius (MagicDNS,
resolved at start: 100.121.87.116) as background on any door.  A POST to
`/v1/chat/completions` or `/v1/messages` on the interactive door takes a 600 s
lease (renewed when the response ends); a background POST while it is live is
held - never forwarded - until the lease expires or a 500 s cap, then answered
`503` with `Retry-After`.  GETs pass untouched.  The engine therefore never sees
a background request between two interactive turns, so the live chain survives
at any depth.  Measured: a background POST from pius during a 20 s test lease was
held 3.0 s and refused (`503`), and the next interactive turn reused 180 of 185
tokens in 326 ms.  The lease also makes a chain probe trustworthy with hindsight
left running: its POSTs are classified `src=background`, so the proxy log must
show no admitted (`status=200`) background line *between* the probe's two turns
(one before turn 1 is harmless - it cannot clear a chain that does not exist
yet); the 503s are the mechanism working.  The engine itself is no longer reachable from the tailnet
(`tiberius:8081` refuses; the server passes `--host 127.0.0.1`).  The trade-off is
policy, not mechanics: a 600 s lease also keeps hindsight out for ten minutes
after the last message, so its consolidation lives in the gaps and at night.
Parking and disk sessions remain the fallback for what the lease cannot cover (a
restart, or a second interactive client).

**Disk sessions measured (v0.2.9, `--slot-save-path` now set).**  `SAVE` streams
the K/V from the pools into the file: 3.89 GB for the 250k conversation in 5.1 s
(760 MB/s), with 354 MiB of live state plus the 384 MiB floor as its RAM need.
`RESTORE` is not streamed - `session_file_read` fills a `SavedConversation` in
host RAM before `conversation_snapshot_restore` pushes it - so the same file
asked for 3,727 MiB plus the floor against 2,050 MiB available and was refused.
The disk path therefore restores conversations whose image fits free RAM (~50k
and below: 391 MB plus the floor) and survives both a background request and a
restart, which parking does not, but it does not rescue 250k on this box.

**Why a refusal destroys the copy (root cause, v0.2.9).**  `park_source`
(`generate.cpp:10655-10694`) runs `drop_superseded`, then `make_room`, then the
RAM loop `while (!admit() && ... conversations.evict_oldest()) ++evicted;` - so
a park that is then refused (`if (!admit()) ... skip parking ...`) has already
evicted up to `slots()` parked conversations, pure LRU, and the main session's
chain is cleared after the park (`14644-14652`, root included).  Parked copies
live in host RAM only; a restart loses them.  The smallest engine-side fix is to
make the park transactional (stash the evicted entries, roll back on every
refusal, commit only after `put()`); a one-line stopgap drops the eviction loop
so a refusal never evicts.  Neither helps 250k: its K/V alone is ~4.1 GB against
863 MiB of available RAM and a 2,048 MiB budget - that needs a lease keeping
background jobs out while an interactive session is live, or more RAM.  `--prompt-cache` is not the lever for that term:
three checkpoints instead of six left the 2.4k image at 391 MB (2,433 tokens)
against 391 MB at 2,435 with six, so the constant is elsewhere in the image.

Settings that mattered, each from a measurement: `--conversation-cache-min-free-mib
384` (the 2,560 default refused: "need 373 MiB plus 2560 MiB floor, 1466 MiB
available"; even 512 skipped at "need 728 MiB plus 384 MiB floor, 802 MiB
available"); `--conversation-cache-slots 4` (with 2, a third conversation evicted
the oldest - ours - one park after it was written); `--conversation-cache-min-tokens
1536`; `--conversation-cache-park-gain 512`; `STRATA_KV_GROW_HOLD=1`.

**Side benefit for the background client**: hindsight's own multi-turn jobs now
report `3309 reused + 1242 read` at 92-100 tok/s where they used to re-read.

### v0.2.9 (engine 0.1.55)

The pin moved to c62d5e3a (v0.2.9, engine 0.1.55).  All three local patches merged
with no hunk conflicts - every region they own moved only in line numbers - and
the regenerated set was re-applied to a pristine c62d5e3a tree and reproduced the
merged tree byte for byte before the build.  Deployed as generation 86.

| cell (fresh engine, lambda 1.2) | 0.1.54 | 0.1.55 |
| --- | --- | --- |
| 4,252 read / decode | 460 tok/s / 49.0 | 448 / 49.3 |
| 3,477 read / decode | 381 / 51.0 | 376 / 51.1 |
| 26,134 read / decode | 1,156 / 50.1 | 1,146 / 51.3 |
| chat turn 2 (2,399 -> 2,443 tokens) | 2,392 reused, 557 ms | 2,392 reused, 561 ms |

That 0.1.55 column predates the 2026-11-01 `--kv-grow` config; the current
baseline is the ab26 0.1.55 arm below (491.2 / 56.9, 405.7 / 64.4, 1,250.8),
which matches the kv-grow figures in `profiles/nixos/strata.nix`.  ("Greedy"
in these rows is temperature 0 plus the server's qwen4exp model-card defaults -
a non-thinking request also gets `presence_penalty 1.5`, because the run
config's `sampling` block pins only temperature.)

The reads are 1-2.4% slower and the decode equal to 2.4% faster, all inside this
harness's spread; the chat turn's answer is the same sha as on 0.1.54.  Upstream's
headline for Linux NVIDIA - the Gated DeltaNet prompt kernels on the tensor cores,
2.6-5.7% faster prompts on an A4000 / RTX PRO 5000 - does not engage on this sm_75
card.  The tool-call fixes (#4663: a tool the conversation already used counts as
declared; #4702/#4703: fenced or indented calls are no longer run) are agent-side
and not observable with the twelve-prompt set used here (12/12 before and after).
The parallel-request defaults do not apply (this lane runs --batch 0), and the
per-card engine code (#4662) does not either: the Nix build is explicitly sm_75.

The bump is kept for the fixes, not for speed.  One operational trap found while
measuring it: `nix build --no-link` outputs are collected by the box's daily
`nix-gc.timer` within minutes, so the first 0.1.55 build vanished before it could
be measured; deploys use `nixos-rebuild switch`, whose generation pins the
closure.

### v0.2.10 (engine 0.1.56)

The pin moved to `ffa80d73` (v0.2.10, engine 0.1.56) on 2026-11-03.  The rebase
needed two keep-both resolutions in `generate.cpp` (0.2.10's new `keep_sync()`
at the request-ending pin release, and the `use_mtp` -> `draft_on` rename in the
`drafted` guard); `no-web-ui.patch` and `avx512-bw-tier.patch` applied cleanly,
and the regenerated set applied to the fetched tree reproduces the merged tree
byte for byte.  A tiberius-native build succeeded and the binary reports 0.1.56
with the DAX-window, refill-pin and SM75-series markers.  Measured 2026-11-03
(`ab26`: production config, three counterbalanced fresh-engine runs per arm, the
ab25 cells; read in tok/s, decode in tok/s):

| cell | 0.1.55 (A) | 0.1.56 (B) |
| --- | --- | --- |
| 4,252 read / decode | 491.2 [482.1-498.2] / 56.93 [56.70-57.20] | 490.4 [487.6-492.0] / 58.77 [58.60-59.00] |
| 3,477 read / decode | 405.7 [403.1-408.4] / 64.40 [63.90-64.90] | 401.8 [393.8-407.7] / 62.07 [61.90-62.30] |
| 26,134 read / 8 gen | 1,250.8 [1,248.6-1,254.1] / 47.47 | 1,249.4 [1,246.2-1,253.0] / 49.57 |

Reads are flat: -0.2% / -1.0% / -0.1%, and the 3,477 B spread overlaps A.  No
decode claim is made: the generated content differs between arms (below), and
the draft acceptance moves with it (P1 49/76 vs 49/72, P2 45/68 vs 34/50).
Answers are bit-identical within an arm across its three runs, but differ
between arms on the 4,252 and 3,477 cells (the 26,134 cell's 8 generated tokens
match).  Two controls bound the cause, and it is not one change:
`data/expert-profile.bin` is byte-identical in the two packages
(`8f59b4aa...`), so the routing input is not it; and 0.1.56 with
`STRATA_PENALTY_PROMPT=1` (the old penalty window) does not reproduce 0.1.55 -
it keeps B's 4,252 answer (`9c40d17d...`, 84 tokens), gives a third 3,477 answer
(`034405e6...`, 86 tokens), and differs from B on 3,477 and 26,134.  The server
does apply the qwen4exp model card's `presence_penalty 1.5` to a non-thinking
request (the run config's `sampling` block only pins temperature; all three
server versions default the family to qwen4exp), so #4590 does move tokens (the
control differs from B), and upstream's other 0.1.56 engine changes - the
verify/expert-grouped/gemm rewrites among them - move them too.  The divergence
is accepted with the bump; `STRATA_PENALTY_PROMPT=1` is the documented window
escape, not a parity switch.  Quality: the eval80 exact-answer set scores
61/80 (A) against 58/80 (B) - arithmetic 19 vs 17, logic 10 vs 9, the other
categories equal - a 3-task gap inside the set's binomial noise (1 sigma about
5.4 tasks).  Net: no speed or quality win on this card; the bump is taken for
the serve-layer tool-call fixes and #4590, with the deterministic answer change
recorded.  #4677 does not touch these cells: the stop-bound park fix is HIP-only
(see the box note above), so the local park/restore work still has no upstream
counterpart.
DFlash2 (CUDA 8.6+) and the all-cards split engine (two or more cards) do not
select for this card.  Two start-time checks on deploy: 0.2.10's serve runs
`drafting.apply` (Auto must resolve to the MTP layer on sm_75) and
`vram_fit.fit_start`, whose only CUDA knob is `--kv-resident` - a KV window
turns `--kv-grow` off in the engine, so if the journal prints `KV window ...`
the 262144 start lost the module's elastic-KV win and the fitter's estimate
needs a look.  An offline pre-check of 0.1.56's `engine_args()` returned the
production args byte-identical (no `--kv-resident`; drafting resolves to MTP),
but that is not what a real start does: `fit_start` prices the card with the GPU
idle and its `drafting_vram_mib()` then sees memory the offline check did not.
The first 0.1.56 start (generation 97) printed `short of GPU memory ... (KV
window 4096 tokens in VRAM)` and ran with `--kv-resident 4096`: `--kv-grow` was
off (the engine logged it) and the DAX window fell to 2.70 GiB (the register
call shrank 5.52 -> 4.58 -> 3.64 -> 2.70).  A restart reproduced it.  Fixed by
pinning the fitter off this knob with `user_args = [ "--kv-resident" "0" ]` in
the run config: the fitter treats a `user_args` value as the person's, and 0 is
the engine's unset value (`o.kv_resident <= 0` keeps `--kv-grow` allowed).
Verified on generation 98: the engine args carry `--kv-grow` and
`--kv-resident 0`, the log prints `elastic K/V: 16384 of 262144` and no
`--kv-grow is off`, and the DAX window is back to layers 0..5 / 5.52 GiB.  The
fitter still prints its `short of GPU memory` line although it changes nothing -
cosmetic.

### Other 0.2.7 findings

- `--mtp-draft-vocab`: the base subset can be produced - `data/draft_vocab_en.bin`
  ships in the upstream source tree, and `tools/draft_vocab.py --corpus` extends
  it (43,099 ids from the engine's own sources at 0.995 coverage).  Measured
  2026-10-30: no decode gain here (see below), and CJK drafting dies (Han 28 of
  55,328 ids), so it is not used.
- `--vram-reserve-mib 768` (upstream's answer to the 475 MiB-free warning)
  measured 22.0 tok/s against 22.1 on the 4.2k cell and cost 2 points of hit rate
  by taking ~400 cache slots, so it is not carried either; the routing hit rate
  keeps the card out of the #2065 paging regime.

## Long context, measured (2026-10-29)

Deployed config (route prior on, int8 KV, 262,144), cold prompt, one request per
size, real corpus repeated into a haystack, a code word at 50% depth (found in
every cell), greedy, thinking off:

| prompt tokens | read | read rate | decode, 8-token reply | decode, 171-194 tokens | hit |
| --- | --- | --- | --- | --- | --- |
| 31,526 | 31.1 s | 1,015 tok/s | 80.2 | - | 99.1% |
| 62,091 | 48.4 s | 1,282 | 47.4 | - | 99.3% |
| 122,989 | 85.0 s | 1,447 | 49.3 | 58.1 | 98.6% |
| 239,242 | 163.3 s | 1,465 | 53.5 | 69.2 | 99.3-99.5% |

The 32k cell was the first request after a restart (cold graphs, cold page
cache); from 64k up the read rate converges on the Optane/PCIe stream, so a
250k prompt costs ~2.7 min of read and the decode rate holds at 55-70 tok/s to
the end of the native window.

**Cached turns at 250k.** The exact repeat reused 225,280 of 239,241 tokens and
took **14.5 s** instead of 163 s; the append-only turn reused the same 225,280
and took **14.9 s**. Reuse is chunk-prefix matching (28,160-token chunks; the
final partial chunk is re-read), so append-only history is cheap but a prompt
that diverges *inside* the document reused 0 and paid the full 163 s (measured
on a summary request that dropped the needle line).

**Past the native window.** The model card (`Qwen/Qwen3.8-Flash-Next`) states
262,144 natively and extensible to 1,000,000 with YaRN (`rope_type: yarn`,
`factor: 4.0`, `original_max_position_embeddings: 262144`; factor 2.0 is its
recommendation for ~524k).  The GGUF and the HF config both declare 262,144 with
`rope_type: default`, and the engine passes no rope scaling, so anything longer
is extrapolated.  A second engine booted with `--max-context 524288`:

| | 262,144 (deployed) | 524,288 |
| --- | --- | --- |
| expert-cache slots | 6,257 | 4,221 |
| 128k read / decode / hit | 1,447 tok/s / 49.3 / 99.1% | 1,238 / 40.3 / 90.8% |
| 478k read / decode / hit | - | 1,176 / 26.8 / 91.1% |

A 478,493-token prompt read in 406.7 s and the needle at mid-document was still
found, so the engine itself is stable there - but that cell is outside the native
window and is exactly where the card recommends YaRN, and doubling the KV window
costs 2,036 expert slots: hit 99.1 -> 90.8% and decode -18% at 128k.  The
deployed lane stays at 262,144.  A 1M lane is a config change, not engine work:
the engine implements YaRN (`--rope-scaling yarn --rope-scale 4 --yarn-orig-ctx
262144`; the model file carries no `rope.scaling.*` keys, so it is CLI-only),
and the card's own recipe is that plus a `factor` sized to the expected context
(2.0 near 524k, 4.0 for 1M).  It is not deployed because of the slot cost above
and because the card warns static YaRN degrades short-text quality.
