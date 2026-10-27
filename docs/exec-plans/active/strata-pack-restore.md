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

### What the router does NOT fix: the per-turn prompt read

An append-only agent turn still re-reads its whole prompt: a 2,127-token first
request reads in 8.5 s, and the same prompt with one sentence appended reads in
8.5 s again (`reused 0`).  A 2.1k-token prompt routes to essentially the whole
pack, so the read is the pack, not the append.  `--prompt-cache-root 1024` was
measured for exactly this case (omp/pi's ~2k boundary sits under the 2048
default) and **did not change it**: the appended request reused 0 tokens at
either root.  The cache's roots are not what an in-conversation append needs, so
the flag is not carried.  The per-turn read is the remaining interactive cost;
the levers that could touch it (a conversation cache that parks K/V between
turns, or a smaller expert union per chunk) are engine work, not config.

### Other 0.2.7 findings

- `--mtp-draft-vocab` needs a base subset (`draft_vocab_en.bin`) that the Nix
  package does not ship; `tools/draft_vocab.py` can extend one but not create it
  from nothing, so the +2.7-3.1% English decode it reports on upstream's cards is
  not reachable here without generating a base from a large corpus.
- `--vram-reserve-mib 768` (upstream's answer to the 475 MiB-free warning)
  measured 22.0 tok/s against 22.1 on the 4.2k cell and cost 2 points of hit rate
  by taking ~400 cache slots, so it is not carried either; the routing hit rate
  keeps the card out of the #2065 paging regime.

