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

The engine has a parking mechanism for exactly this shape
(`--conversation-cache-mib/-slots/-min-tokens`; this box pins the budget to 0,
because 0.2.3's auto-sizing takes up to 8 GiB on a 7.4 GiB box).  It is **not
sufficient on its own**: a checkpoint is the recurrent state (~118 MB of GDN,
QSA indexer tails and PLE history) and "the KV cache itself is positional and
stays where it is", so a parked conversation keeps its K/V only under
`--kv-grow`, whose gate requires `!o.resident_cpu_experts` - i.e. dropping the
1 GiB `--resident-budget-gib` host tier.  The elastic K/V also frees the cells a
short conversation never reaches back to the expert cache.

The alternatives and their measured or documented costs:

* `--kv-grow` + parking (drop the host tier): the only configuration where a
  parked conversation's K/V survives a foreign prompt ("the longest parked
  conversation, in tokens (--kv-grow keeps the K/V that long while it could be
  restored)").  One config, two variables to price: the tier loss (8% of the CPU
  pool per window measured on pre-router misses; at 2% misses it should be much
  less) and the elastic K/V itself.  Untested here.
* serialising the clients: zero cost, works today, needs the background jobs to
  yield to interactive turns.
* `--slots N` (per-slot K/V and chain, `bs[].checks`): the batch path does not
  run the MTP drafter unless `--batch-mtp` (opt-in) is also set, so a slot-served
  turn would lose the ~1.7 tokens per step the decode numbers above depend on;
  it also wants a second slot's K/V at 262k against ~475 MiB free.  Re-measure
  both before considering it.
* a per-conversation K/V outside the batch path: engine work, the last resort.

None of these is deployed: this box serves hindsight and interactive traffic on
the same port, and the collision costs a turn its reuse (9.5 s at 2.4k, 188 s at
250k) but nothing correctness-wise.

### v0.2.8 (engine 0.1.54) and the router at 1.2

The pin moved to 870aedd9 (v0.2.8, engine 0.1.54).  The three-way merge against
the v0.2.7 tree needed no hunk resolution in tiberius.patch or no-web-ui.patch
(only line numbers moved); avx512-bw-tier.patch had one conflict in
`cpu_require_expert_support()`, where 0.2.8 rewrote the message to explain a pack
without native_experts.txt - the merge keeps upstream's structure and the
VBMI-free ISA list.  Built on tiberius from the local flake; the regenerated
patch set was re-applied to a pristine 870aedd9 tree and reproduced the merged
tree byte for byte before the build.

| cell (fresh engine, greedy) | 0.1.52 | 0.1.54 @1.5 | 0.1.54 @1.2 |
| --- | --- | --- | --- |
| 4,252 read / decode | 467 tok/s / 55.6 | 467 / 54.3 | 460 / 49.0 |
| 3,477 read / decode | 382 / 61.6 | 388 / 61.4 | 381 / 51.0 |
| 26,134 read | 1,254 | 1,155 | 1,156 |

The 26k read spread is run-to-run (ab24 measured 1,153-1,278 across the same cell
family); decode parity between the two engines matches 0.2.8's own note that its
gains are measured on other cards.  Tool-call parsing measured 12/12 on both
engines with a two-function, twelve-prompt set - too clean to exercise the 0.2.8
recovery, so there is no local evidence for it beyond upstream's 1,462 turns.

**The router at 1.2, not 1.5.**  0.2.8 turned the route prior OFF by default for
12 GB cards, tying it to repeated text in long sessions; this box keeps it
explicitly, and the failure mode reproduces here at 1.5:

* a 9-turn continuation probe, two runs per arm: off no identical turn; 1.2 none
  in either run; 1.5 one clean run and one with **five identical 301-character
  answers in a row** and 60.8% cross-turn 8-gram repeats.
* an 80-task exact-answer set (arithmetic, units, logic, Python output, structured
  data): off 61/80, 1.2 60/80, 1.5 56 and 58 in two runs (sigma ~3.8).
* cost: 1.5 is 10-17% faster on the 4.2k/3.5k cells; 1.2 is still 2.2x the
  un-routed lane on the 4.2k cell (49.0 against 22.4 tok/s).

**Rejected on measurement.**  The MTP draft vocabulary built from the engine's own
sources (43,099 ids; English and code at 100%/99% coverage; Han 28 of 55,328):
decode 52.8 / 62.5 against 54.3 / 61.4 - no gain, and CJK drafting dies, so it is
not used.  `--prompt-cache-root 1024` and `--vram-reserve-mib 768`: no effect (the
former) and a hit-rate cost for no decode (the latter).  The end-of-prompt
checkpoint patch described above: dropped.

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
