# HFT-style latency tricks on tiberius — what applies, what is already spent, what is wasted

Status: **investigation complete; one measurement still in flight** (governor/EPP A/B).
Written 2026-10-13. Labels: **[M]** measured, **[D]** derived, **[E]** estimate, **[U]** unknown.
Companion: `tiberius-kernel-tuning.md` (kernel options, AVX-512 measurement, kernel A/B).

## 1. Bottom line

**The decode window is a bytes/rate term, not a latency term, so the HFT playbook has
almost nothing left to fix here.** Of a 91.18 ms window (P1), 73.21 ms is host-side
`pool+plan`, 17.86 ms is `gpu_wait`, and staging+commit together are 0.13 ms (0.15 %);
the pool moves the miss-expert stream at **6.2 / 5.8 GB/s — 85–90 % of the best
single-path Optane rate ever measured on this box (6.88 GB/s)** [M]. Run-to-run
deviation of that 73 ms term is **0.06 ms (0.08 % of the window)** [M] — i.e. the
jitter that HFT tricks exist to remove is 60–100× below the harness's own ±0.3 %
measurability floor. Pinning is already done *by the engine*, the weights are already
PMD-mapped, and there is no IOMMU, no NUMA spread, and one memory channel shared with
the DCPMM.

## 2. Window anatomy (stock kernel, promoted engine, mean of 3 runs, sd ≤ 0.06 ms) [M]

| cell | per-window | gpu_wait | pool+plan | host staging | commit | windows | tok/window |
|---|---|---|---|---|---|---|---|
| P1 | 91.18 ms | 17.86 | 73.21 | 0.080 | 0.054 | 101 | 2.53 |
| P2 | 77.48 ms | 17.79 | 59.58 | 0.066 | 0.057 | 107 | 2.39 |
| P3 | 85.84 ms | 17.94 | 67.79 | 0.066 | 0.056 | 27 | 1.89 |

`pool+plan` is 77–80 % of the window; `gpu_wait` 20–23 %; staging+commit 0.15 %.

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
| **Busy-poll vs yield** | The engine already spins everywhere (host spins on a volatile sequence before any CUDA call; workers `_mm_pause`-spin; doorbells are mapped host memory). What remains is ~144 pool barriers/window (wait-park/drain/re-park) ≈ 0.7–1.4 ms ≈ **1–1.5 %** [E]. | 1–1.5 % | **the only live HFT-style surface** — and it is *unmeasured* because the instrumentation is off (see §4) |
| **NUMA / DIMM placement** | Single socket, single NUMA node, one 8 GB DDR4-2400 DIMM **and** the DCPMM on iMC#0/Chan#0 — 5 of 6 channels empty; the pool is documented DRAM-bound; a pinned thread cannot outrun the channel [M]. | hardware | **nothing to steer** (the real fix is a second DIMM) |
| **Kernel variants / preempt / isolcpus / nohz_full / rcu_nocbs** | `preempt=full` was a clean null, CachyOS v4 ≤0.6 % confounded (`tiberius-kernel-tuning.md` §7) [M]; jitter is 0.08 % of the window, so tick/RCU/callback steering has nothing to recover; `CONFIG_NO_HZ_FULL=y` is inert with no cpulist; `isolcpus` would strand 11 of 24 threads on a swapping box [M]. | ~0 | **wasted** (all boot-only except in-kernel knobs, and none addresses bytes) |

## 4. Where the honest EV is: instrumentation, not sysctls

1. **Turn on the engine's existing instrumentation (zero risk, highest information).**
   `--stats` prints the pool phases (`wait-park / drain / re-park` ms/token) that
   separate *slow at the work* from *slow at the synchronisation* — "opposite fixes",
   per the engine's own comment — and `STRATA_IO_STATS=1` prints the prefetch counters
   (`N read ahead, X MB by pread, used/unused/skipped`). Neither is set in production
   (`generate.cpp` reads them behind `--stats`; the module never passes it). One harness
   session answers whether the ~144 barriers are worth attacking at all.
2. **Measure the round-trip floor with the engine's own `--no-pool` arm.** The authors'
   reference figure is 38.73 ms/token against a 26.32 ms pure-GPU floor, i.e. 12.4 ms of
   round trip with *no expert work at all*; on this box that single number is the ceiling
   for every wakeup/jitter/isolation idea. A/B only (it changes output).
3. **Spend the ~20 % device-idle fraction.** The Optane is busy 73/91 = 80 % of a window;
   deepening the pre-read ring (`STRATA_STAGER_RING=4` today, default 16; plus
   `STRATA_IO_PREFETCH*`) is the only cheap way to overlap the miss stream into that
   idle. Metric: `pool+plan` and the prefetch counters. Risk: RAM on a 7.4 GiB box.
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
6. **Re-probe the Optane concurrently [U].** The 8.9–9.0 GB/s aggregate implied by the
   engine's own read counters is above every single-path figure measured so far; if two
   concurrent readers really do sum past 6.8 GB/s, the "device ceiling" framing (and the
   Maya decision built on it) changes.

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

- `STRATA_ADAPT_OVERLAP=0` (prod config) matches **no symbol** in the 0.1.42 tree — do not
  read it as "overlap is disabled, turn it on"; the live overlap knobs are
  `STRATA_STAGER_RING` and the `STRATA_IO_PREFETCH*` family [M for the tree, U for 0.1.43].
- `smaps KernelPageSize: 4 kB` on dax VMAs is nominal metadata; the authoritative
  signal is `FilePmdMapped` (71.9 GB) — the pack *is* PMD-mapped [M].
- `processor.max_cstate=` only affects `acpi_idle`; this box runs `intel_idle`, so that
  cmdline is inert [M].
- The `STRATA_REFILL_PIN_SRC` copy classes (0.040 vs 0.867 ms per 2 MiB) measure *async
  issue*, not device bytes: 0.040 ms ⇒ 52 GB/s is above the device's measured ceiling [D].
