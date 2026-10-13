# HFT-style latency tricks on tiberius — what applies, what is already spent, what is wasted

Status: **complete, mechanism question closed.** The governor/EPP A/B is a conclusive null
(§5); the instrumented session and its generate-mode follow-up are in §4 — io counters work,
and the pool term is shown to be *work* (drain) with the barriers structurally nil, so every
host-side latency family in §3 is closed by measurement. Written 2026-10-13. Labels: **[M]**
measured, **[D]** derived, **[E]** estimate, **[U]** unknown.
Companion: `tiberius-kernel-tuning.md` (kernel options, AVX-512 measurement, kernel A/B).

## 1. Bottom line

**The decode window is a bytes/rate term, not a latency term, so the HFT playbook has
almost nothing left to fix here.** Of a 91.18 ms window (P1), 73.21 ms is host-side
`pool+plan`, 17.86 ms is `gpu_wait`, and staging+commit together are 0.13 ms (0.15 %);
the pool moves the miss-expert stream at **6.2 / 5.8 GB/s — but that stream is served from
the ZFS page cache and the dax mapping, not the Optane media** (storage reads 0.4–607 MB per
request against 21–81 GB of expert reads, §4.1), so the figure is a cache/one-DRAM-channel
rate, not a device-bound one. Run-to-run
deviation of that 73 ms term is **0.06 ms (0.08 % of the window)** [M] — inside the
harness's own ±0.3 % floor, by ~4× (the 60–100× figure belongs to the pool workers'
run-queue wait, 32–227 ms over 5 724 s of runtime each — a different measurement).
And the two compute-side manipulations that were tried both failed to move it: a wider
ISA (−5.9 % at best, §2) and a ×3.2 median clock (§5). Pinning is already done *by the
engine*, the weights are already PMD-mapped, there is no IOMMU, no NUMA spread, and one
memory channel is shared with the DCPMM. The box also serves while **~1.07 GB of the
engine is swapped out** against a 948 MB ZFS ARC on 7.5 GB of RAM [M] — a bound on any
further tuning, and the reason §3 rejects a hugetlbfs reservation.

## 2. Window anatomy (stock kernel, promoted engine, mean of 3 runs, sd ≤ 0.06 ms) [M]

| cell | per-window | gpu_wait | pool+plan | host staging | commit | windows | tok/window |
|---|---|---|---|---|---|---|---|
| P1 | 91.18 ms | 17.86 | 73.21 | 0.080 | 0.054 | 101 | 2.53 |
| P2 | 77.48 ms | 17.79 | 59.58 | 0.066 | 0.057 | 107 | 2.39 |
| P3 | 85.84 ms | 17.94 | 67.79 | 0.066 | 0.056 | 27 | 1.89 |

`pool+plan` is 77–80 % of the window; `gpu_wait` 20–23 %; staging+commit 0.15 %. Per the
instrumented session (§4), that miss stream is served overwhelmingly from the ZFS page
cache and the dax mapping — storage reads are 0.4–607 MB per request against 21–81 GB of
expert reads — so read the 6.2/5.8 GB/s figure as a *cache/one-DRAM-channel* bound for the
majority and the 6.8 GB/s dax ceiling for the registered window, not as an Optane-media
rate.

**Bytes arithmetic [D]:** 131 292 / 141 472 / 23 945 expert lookups for 256/256/51
tokens = 513/553/470 lookups/token at 82.9/87.2/66.1 % hit ⇒ 180/145/325 MB of miss
bytes per token ⇒ over the measured pool+plan per token (28.9/24.9/35.9 ms) that is
**6.2/5.8 GB/s effective** against the measured Optane classes (CPU mmap 6.88,
registered DMA 6.57–6.87, pageable 2.3–2.4, PCIe-from-DRAM 12.2). The stream is ~85–90 %
of the device's best path, and the ISA test bounds the compute share: the AVX-512 tier
moved pool+plan by −1.1/−5.7/−5.9 % [M], so **~85–90 % of the pool is ISA-insensitive —
it is not FLOPs** [D]. The one instrumented alternative (CPU-share arms) *lost* 7 %,
consistent with decode needing the same byte stream.

*Anomaly to re-probe [U]:* the engine's own line reports 81 474.8 MB / 75 354.1 MB of
expert reads per request ⇒ 8.9–9.0 GB/s sustained, above every single-path measurement
— possibly two concurrent readers (host mmap + device DMA). Treat 6.8 GB/s as a
per-path ceiling, not necessarily an aggregate one, until re-probed concurrently.

## 3. Family-by-family verdict

| HFT family | what the data says here | ceiling | verdict |
|---|---|---|---|
| **CPU pinning / core isolation** | The engine pins itself: 11 pool workers 1:1 on logical CPUs 1–11 (one per physical core, SMT siblings excluded by topology detection), host thread on 0 (`ExpertPool(..., /*pin=*/true)`, log line 18) [M]. Workers' runqueue wait: **32–227 ms over 5 724 s** of runtime each — never starved [M]. | ~0 | **already spent** |
| **RT scheduling (SCHED_FIFO/RR)** | Zero RT anywhere in the engine (no `sched_setscheduler`/`setpriority`/`nice` in src, all threads SCHED_OTHER prio 120) [M]; nothing contends for the pinned cores; jitter already 0.08 % of the window. | ≤0.5 % [E], below the 0.3 % floor | **wasted, mildly negative EV** (an RT host thread can starve the io/prefetch worker) |
| **Frequency / governor / EPP** | `intel_pstate` active, governor `powersave` ×24, EPP `balance_performance`, EPB 6, `min_perf_pct=28`, sampled 1.2 GHz on 23/24 idle CPUs, `no_turbo=0` [M]. Cores do **not** idle inside a window (the pool `_mm_pause`-spins 20 ms before sleeping vs a 1.5 ms/layer gap) [M]. | only the post-idle entry ramp (ms-scale, once per request) | **measured — see §5** |
| **C-states** | `intel_idle`, states POLL/C1/C1E/**C6 (133 µs exit)**; C6 84.9 % of residency mostly *between* requests; the engine cores are out of C6 ~72 % during serving, but they spin in userspace rather than idle during a window [M]. | ~130 µs per window start = 0.14 % of 91 ms | **mostly wasted**; `idle=poll` is the worst risk/benefit here (24 threads burning power next to an 82/85 °C Optane) |
| **IRQ steering / irqbalance** | irqbalance active (dynamic masks); the nvidia MSI-X (irq 47) lands on cpu21 — an SMT sibling of core 9, **not** the host core; xhci on cpu5, ahci on cpu11 with 26.6 irq/s are the only engine-CPU fires [M]. | ≤0.5 % [E] | **wasted** (cheap to do anyway — `echo <mask> > /proc/irq/47/smp_affinity_list`) |
| **Hugepages / TLB** | The pack is **already 2 MiB PMD-mapped** (`FilePmdMapped` 71.9 GB against 20 MB of PTEs; 0–737 major faults for 21–81 GB of reads) [M]; the pinned vs pageable *host* tier was already measured byte-identical; `HugePages_Total=0`, THP=madvise with `thp_fault_fallback 12 916` on the anonymous side [M]. | ~0 on the pack; unknown-but-small on the 1.37 GiB anon arena | **wasted for weights**; hugetlbfs reservation would pin ~1.4 GB of non-swappable RAM on a box already swapping 1.07 GB — do not |
| **Busy-poll vs yield** | The engine already spins everywhere (host spins on a volatile sequence before any CUDA call; workers `_mm_pause`-spin). The remaining surface was thought to be ~144 pool barriers/window ≈ 1–1.5 % [E]; the `generate`-mode phase split (§4) replaced that conjecture: `wait-park` and `re-park` read 0.000 on every run, and the drain decomposes completely into the gate/up + quantize + down row work. | barriers bounded at ≤7 × 10⁻⁶ of the pool term [M]; the `~1–1.5 %` estimate is **retired** | **closed** — nothing to buy here |
| **NUMA / DIMM placement** | Single socket, single NUMA node, one 8 GB DDR4-2400 DIMM **and** the DCPMM on iMC#0/Chan#0 — 5 of 6 channels empty; the pool is documented DRAM-bound [M]. | hardware | **nothing to steer** — and the channel is not this pool's limit: the same-window probe measures 18.4–18.5 GB/s achievable against the pool's 6.2 (~34 %), so a second DIMM raises a wall the pool is not at (it would matter for a *CPU-resident* lane, which is the use case the maya recon's DIMM note belongs to) |
| **Kernel variants / preempt / isolcpus / nohz_full / rcu_nocbs** | `preempt=full` was a clean null, CachyOS v4 ≤0.6 % confounded (`tiberius-kernel-tuning.md` §7) [M]; jitter is 0.08 % of the window, so tick/RCU/callback steering has nothing to recover; `CONFIG_NO_HZ_FULL=y` is inert with no cpulist; `isolcpus` would strand 11 of 24 threads on a swapping box [M]. | ~0 | **wasted** (all boot-only except in-kernel knobs, and none addresses bytes) |

## 4. Where the honest EV is: instrumentation, not sysctls

**Instrumented session run 2026-10-13 [M].** A `--stats` + `STRATA_IO_STATS=1` session
(3 runs, answers 9/9 identical to the canonical ones when the expert split is pinned):

1. **`STRATA_IO_STATS=1` works and is revealing.** The engine reads 81 474.8 / 75 354.1 /
   21 486.1 MB of expert bytes per request while the OS reads from storage only **66–607 MB
   (P1), 0.4–0.5 MB (P2), 0.0 MB (P3)**, and the page cache held 55 400 MB / 75 354 MB /
   21 486 MB at the read (versus the engine's own expected 26 075 / 0 / 0 MB). So the decode
   miss stream is served almost entirely from the ZFS page cache and the dax mapping, not
   from the Optane media — the "6.2 GB/s out of the Optane" framing in §2 is better read as
   a *DRAM/one-channel* bound for the cached majority plus the 6.8 GB/s dax path for the
   registered window. This also explains the >8.9 GB/s aggregate the earlier counters
   implied, and it points the hardware fix where the recon already put it: the second DIMM.
2. **`--stats`'s `pool phases` row is a `generate`-mode report and does not print in serve
   mode** — so the wait-park/drain/re-park split (the item that decides work-vs-synchronisation)
   is *not* obtainable from the served configuration. Getting it needs either a
   `strata generate`-mode diagnostic run (same kernels, different loop) or an engine change
   (no upstream contact, per the current decision). Recorded rather than assumed.
3. **A harness-scoping rule, not a production property: an unpinned start-up probe makes the
   served text a trajectory variable.** Two independent arms show it. (a) DiagSession's *pilot*
   lost the recipe env, so the engine ran v0.1.42's timing probe itself — and that probe
   *adapted mid-run*, 0.34 → 0.50, diverging from the pinned run in **1 of 3** comparisons
   (P2 only, hash `2ca1ffdb`, 369 B / 222 tokens). (b) The deliberately unpinned arm let the
   probe *start* elsewhere — 0.32 against the campaign's pinned 0.34 — and only **3 of 9**
   answer hashes matched (P1 462→480 B, P2 398→379 B, P3 identical). **Production pins the
   split** — `profiles/nixos/strata.nix:365` sets `STRATA_PCIE_FRAC_DEFAULT = "old"` (guarded
   at `pkgs/strata-sm75/default.nix:204-205`) — which is *why* the served text is
   restart-deterministic, and that pin is load-bearing for the answer-hash neutrality checks
   every campaign here has relied on. Harness launches must keep the same pin (explicitly, or
   by preserving the recipe env) before comparing answers or means: a mid-run adapting probe
   and a differently-started probe are two distinct failure modes, both fatal to hash
   comparisons.
4. **The instrumentation itself costs ~0.5–0.7 %** (pool+plan 73.70 vs 73.22 ms, decode
   27.90 vs 28.00 on P1, with identical answers): enable diagnostics to *see* a mechanism,
   never to *benchmark* one.

**Generate-mode follow-up, same day [M] — the phase split, and it is WORK.** `--stats` prints
the three phases only in `generate` mode, so the question was re-asked there (3 runs, 92 verify
windows / 256 tokens each, ~27 tok/s decode, production args and env preserved including the
`STRATA_PCIE_FRAC_DEFAULT=old` pin):

```
  pool phases              wait-park 0.000  drain 67.759  re-park 0.000  ms/token     (67.718 / 67.946 in the other two)
  pool multi   gate/up 42.80  quantize 0.12  down 24.86  ms/round                     (sums to the drain within 0.003 ms)
```

*Unit note — the engine's own label is wrong:* the row prints `ms/token`, but the divisor is
the **window** count. 67.76 × 92 windows = 6.23 s, exactly the run's reported drain total and
the same per-window quantity as the campaign's `pool+plan` (P3: 67.7–67.9 both ways); × 256
tokens would be 17.3 s, *more* than the 9.475 s decode it came from. Quote it as per-window and
treat `ms/token` there as a known label bug — anyone comparing it to `pool+plan` will otherwise
inherit a 2.8× phantom. The arithmetic above is the verification, and the source shows these rows
are error-prone independently of us: its own comment on the neighbouring rings row reads "the
denominator is the number of positions, not the number of generated tokens. Dividing by
`n_layers * decoded` printed '240 of 192', which is a reporting bug that looks like a ring firing
more often than it should" (`generate.cpp:13076-13079`, in the 0.1.42 tree — a comment can't be
verified against the deployed binary, so the arithmetic above is the verification and this only
corroborates that the authors treat these divisors as risky) — re-derive every denominator here;
do not trust the label.

- **The synchronisation terms are nil, structurally.** `wait-park` and `re-park` are exactly
  0.000 in all three runs, and the engine's own estimate for the multi path bounds them at
  ≤0.046 ms over the whole run against a 6.23 s drain — i.e. ≤7 × 10⁻⁶ of the pool term.
  Caveat, from the source rather than the measurement: only `ExpertPool::run()` accumulates
  those two counters; the split paths (`run_split*`, which this run demonstrably took — the
  `pool multi` row is non-zero) add their whole duration to `drain` and never time a barrier.
  So 0.000 certifies *no separately instrumented barrier on this path*; a barrier hidden inside
  `run_phase` would sit inside the gate/up and down rows — and those two rows sum to the drain.
- **The drain is the row work, at ~6.2 GB/s.** `gate/up + quantize + down` decomposes the pool
  term completely, so the ~68 ms window term is CPU expert rows streaming the cache/dax-served
  miss stream (§4.1) — not congestion, not barriers. Note that `host_works_` is true (the host
  thread drains through the same claim counter), so `drain` is the *batch's* whole time rather
  than "the workers' time": a large value says the batch is slow, not that the workers are.
- **Independent cross-check:** `/proc/schedstat` `run_delay` across each run is 3.74–3.82 s
  (8.3–9.3 % of the window) and **98.5 % of it lands on cpu0** — the host thread's core — while
  the 11 pool workers' cores accrue 0.5–16.6 ms total. The workers are never queue-starved, in
  agreement with §3's pinning row and with the nil barriers.
- **What this leaves as headroom [M]:** the box's own streaming-read ceiling was measured in the
  same window (1 GiB fresh-mmap buffer, `nix shell nixpkgs#gcc` gcc 15.3.0, plain unaligned
  8-byte loads): 1/2/4/8/12 threads give 14.19 / 17.51 / **18.42 / 18.40 / 18.48 GB/s** — one
  populated DDR4-2400 channel at ≈96 % of its 19.2 GB/s theoretical. The pool runs at 6.2 GB/s,
  i.e. **≈34 % of what the channel actually delivers**, so it is *not* at the memory wall: a
  second DIMM would raise a wall nobody is touching. (The probe streams; the pool reads 1.95 MiB
  contiguous blobs with coarse jumps between them, so the streaming figure is the right
  comparator modulo blob-boundary effects — it is an upper bound, not an exact target. Two
  further caveats from the probe's own header: it reads a *private anonymous* buffer, not the
  page cache and the dax mapping the pool streams from, so the gap implicates the pool or that
  path rather than DRAM as such; and it was built `-O2` with no `-ffast-math`, where the
  single-thread 14.19 GB/s is exactly what rules out a compute-bound scalar loop (that would
  have read at 1–2 GB/s). The curve is flat from four threads up, so the pool's thread count is
  not a lever either.) The remaining upside is engine-side
  (memory-level parallelism, access pattern, compute-vs-memory balance in the row kernels) or
  fewer bytes (cache hit rate / route-tail skip — both already tuned). Every host-side latency
  family in §3 is now closed by measurement rather than by argument.

**Closing test — the resident-pin knob is refused by the engine itself [M].** With
`STRATA_RESIDENT_PIN=1` the engine takes the mlock path and declines it on this box: `locked
resident cache complement ready: resident 1.00 GiB, pinned 0.00 GiB … WARNING: only 0.00 of 1.00
GiB could be page-locked (the RAM left would fall under the reserve); the rest is resident but
pageable, so its copies to the GPU go through the CPU (#1250)`. Six runs (pin0 control / pin1,
3 each, rc=0, service restored) are indistinguishable — P1 9148 vs 9129 ms, 28.0 tok/s both, hit
82.9 % both, identical draft and window counts. So the last untested cheap engine knob is closed
by the engine's own memory policy, not by measurement: it needs RAM headroom this 7.5 GB box does
not have.

1. ~~**Turn on the engine's existing instrumentation**~~ — **done** (the block above):
   `STRATA_IO_STATS=1` answered where the bytes come from, and the `generate`-mode `--stats`
   run answered the phase question — the pool term is work, not barriers.
2. **Measure the round-trip floor with the engine's own `--no-pool` arm.** The authors'
   reference figure is 38.73 ms/token against a 26.32 ms pure-GPU floor, i.e. 12.4 ms of
   round trip with *no expert work at all*; on this box that single number is the ceiling
   for every wakeup/jitter/isolation idea. A/B only (it changes output).
3. ~~**Spend the ~20 % device-idle fraction**~~ — **withdrawn** (§4.1 and §4.6): the stream is
   page-cache/dax served, so device idle is not the constraint and a deeper pre-read ring would
   prefetch into RAM bytes that are already there. That 20 % is an engine-side overlap
   question, not a device one.
4. **Tail latency, if it ever matters, needs a new readout — not a new sysctl.** The
   engine prints timing *means only* (one `stage N: … per window: …` line per request);
   window dispersion is destroyed before it reaches any file, so no parser change can
   recover p95/p99 [M]. The cheap addition is client-side: a copy of the harness driver
   with `stream=True` recording `perf_counter()` per SSE token chunk gives a real ITL
   series (p50/p95/p99/max, stall counts) on the *same* 3 runs/arm; the Prometheus
   endpoint (`/metrics?format=prometheus`) has vLLM-style TTFT/ITL/e2e histograms but its
   ITL is one per-request mean replicated with token weight — it cannot show intra-request
   jitter. `tracefs` `wakeup_rt`/`wakeup` tracers are available for a kernel-level answer
   without installing anything; `cyclictest` (rt-tests) is absent but substitutable.
5. **Regression metric hygiene:** use **`gen_ms`** (1 ms resolution, sd 13 ms = 0.14 %)
   rather than the log's rounded decode tok/s (0.1 tok/s quantisation dominates its
   0.047 sd). With 3 runs/arm the 2σ floor is ~0.29–0.40 % on decode; a single 20 ms stall
   in 101 windows is 0.22 % — i.e. **a tail-only win is invisible to the current design**
   unless it also moves the mean.
6. ~~**Re-probe the Optane concurrently**~~ — **withdrawn** by the instrumented session §4.1:
   the 8.9–9.0 GB/s aggregate came from counters over a stream that is essentially 100 %
   page-cache served after warmup, so it is an mmap-from-cache quantity, not a device rate.
   Nothing to re-probe; and the consequence for item 3 is that the 20 %-device-idle overlap
   idea loses its premise — the bytes are already in RAM, so what remains is the engine's
   CPU-side pool time, which needs the generate-mode phase split (item 1's caveat) to
   localize rather than a deeper prefetch ring.

## 5. Governor / EPP A/B — a conclusive null [M]

Two 3-run sessions, same kernel and engine, identical recipe, **byte-identical answers**
across arms and runs (sha256 P1 `bec0c5e0…`, P2 `b35d8a15…`, P3 `842fcc5d…`):

| | base (`powersave` / `balance_performance`) | `performance` / `performance` |
|---|---|---|
| decode P1 / P2 / P3 (tok/s) | 28.00 / 30.60 / 23.20 | 28.00 / 30.53 / 23.17 |
| pool+plan per window | 73.27 / 59.61 / 67.81 ms (sd 0.05) | unchanged within 0.09 % |
| hit % / drafts / windows | 82.9·87.2·66.1 / 158-200, 151-211, 35-40 / 101, 107, 27 | identical |

**The mechanism proof makes the null conclusive rather than merely unmeasured:** the
policy *did* change the clocks — median over ~2 800 samples 1 200 → 3 888 MHz (×3.24),
time at ≥3.8 GHz 26.8 % → 57.7 %, and a *worker* core at turbo in 56 % → 93 % of samples
— and decode still moved ≤0.22 % with no consistent sign. Under `powersave` the cores
that carry the critical path already reach full turbo (per-sample max median 4 100 MHz);
the governor mostly lifted *non-critical* cores out of their 1.2 GHz dwell. **Whatever the
73 ms of `pool+plan` spends itself on, it is not core clock cycles** — consistent with §2's
bytes/rate arithmetic (85–90 % of the Optane's best path, 85–90 % ISA-insensitive).
The base arm also reproduced the campaign's canonical numbers to 0.1 %, which is an
independent faithfulness check on the harness.

`cpufreq.default_governor=performance` stays available as a boot cmdline, but there is now
no reason to spend it. Runtime equivalent for future tests: `cpupower frequency-set -g
performance` plus the EPP sysfs writes; the harness re-created for this measurement lives
in `/data/gov/` with per-arm `freq.csv` samples.

## 6. Traps recorded

- **Tree-vs-binary knob claims need verification.** The source tree on the workstation was
  0.1.42, so every tree-derived claim here was re-checked against the *deployed* 0.1.43
  binary (`grep -a` on `/nix/store/1j1cf154…-strata-engine-0.1.43/bin/strata`, positive
  control `STRATA_ROUTE_TAIL_SKIP` = 3 hits). `STRATA_ADAPT_OVERLAP` **is** in the binary
  (6 hits) — the prod config's `=0` is a live knob, and the pin is deliberate: the **ab11**
  campaign of 2026-10-12 measured the adaptive path losing 25.6/30.3 tok/s against 27.2/35.2
  with it off (per-arm spread ≤0.1 tok/s; `docs/VALIDATION.md:210-235`) — the docs are the
  durable record by design; the `/data/*` artifact dirs are best-effort work areas, not an
  archive — and in the resident-RAM mode this box runs, adaptive overlap
  is *already* skipped unless `STRATA_ADAPT_OVERLAP_RESIDENT=1`
  (`docs/VALIDATION.md:213-216`) — that opt-in is the arm those numbers came from, so the
  module's `=0` is belt-and-braces against a future default flip rather than the thing that
  disables it. Do not re-run it. Also present: `STRATA_IO_PREFETCH` / `_PF_AHEAD` /
  `_PF_THREADS`, `STRATA_POOL_SPIN_US`, `STRATA_AUX_CPUS`, `STRATA_CPU_YMM`,
  `STRATA_STAGER_RING`. **Absent**: `STRATA_DOORBELL`
  — the skeptic lens's doorbell claim was tree-specific and does not describe this build.
- `smaps KernelPageSize: 4 kB` on dax VMAs is nominal metadata; the authoritative
  signal is `FilePmdMapped` (71.9 GB) — the pack *is* PMD-mapped [M].
- `processor.max_cstate=` only affects `acpi_idle`; this box runs `intel_idle`, so that
  cmdline is inert [M].
- The `STRATA_REFILL_PIN_SRC` copy classes (0.040 vs 0.867 ms per 2 MiB) measure *async
  issue*, not device bytes: 0.040 ms ⇒ 52 GB/s is above the device's measured ceiling [D].
