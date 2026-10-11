# Decode levers re-tested with the SHIPPED sliding-window engine

Engine: /nix/store/a767f19z2y3y3i5rfhzd3r2xbcry2mm3-strata-engine-0.1.29/bin/strata (the packaged
generation-47 engine; window logs 'window on layers 0..5, 5.52 GiB registered (device alias ok)').
Config base: the shipped `strata-iq3-s.json` (STRATA_REGISTER_DAX=1, _MIB=6144). Workload: /data/ab5.py
on /data/real-corpus.txt - warmup, then a fresh 4292-token prompt + 256 gen, then a different region
(3514 tokens) + 256 gen. 13 arms x 2 runs, pass 1 forward and pass 2 reverse, one fresh engine per run.

## Noise floor (the result that governs every other claim)
Three arms are the SHIPPED CONFIG in different spellings - pca (nothing appended), pw11 (--pool-workers 11),
kv8 (--kv k8v4) - and their /metrics blocks are identical (kv=k8v4, pool_workers=11, pcie_frac=0.26,
expert_slots=7487). Pooled over their 6 runs: P1 20.41 tok/s, P2 26.19 tok/s.
Their individual runs: P1 19.6 20.1 20.1 20.7 21.0 21.2 ; P2 23.1 25.6 26.0 26.1 28.5 28.9.
=> identical configs spread +-4% (P1) and +-11% (P2); a >3% 'win' is NOT resolvable at 2 runs/arm.
(Decode tok/s is partly an acceptance-luck metric: P2 ran 1.04-1.18 tokens/window, P1 1.86-2.33.)

Contention: this box is shared. 6 runs showed 'pool + plan' of 126-213 ms/window against a control band of
65-100 ms (CPU-pool starvation from co-tenants; one run also had its VRAM expert cache cut from 7487 to
2995 slots by a co-tenant's engine). 4 of them (kv8-1, kv8-2, rs512-2, rs1024-2) were re-run until clean
(driver checks pool+plan <= 110 ms); they are the numbers below. rs2048-2/P2 (13.9 tok/s, pool 104.5 ms)
stayed contended - it is reported raw and excluded from the rs2048 estimate.

## Arm table (both runs; pool = 'pool + plan' ms/window from `stage 0:`)

| arm | args | P1 tok/s (pool, hit) r1 / r2 | P2 tok/s (pool, hit) r1 / r2 | verdict |
|---|---|---|---|---|
| pca | (none) | 21.2 (80.2, 85.2) / 21.0 (94.0, 85.2) | 23.1 (69.5, 89.0) / 26.0 (78.7, 88.1) | CONTROL (shipped config) |
| pc0 | --pcie-frac 0 | 19.4 (92.5, 81.7) / 20.5 (106.5, 80.2) | 25.5 (74.6, 88.4) / 24.7 (76.7, 88.3) | no win |
| pc5 | --pcie-frac 0.5 | 19.6 (89.4, 84.6) / 19.9 (102.7, 81.6) | 24.0 (70.2, 89.3) / 23.6 (78.3, 88.3) | no win |
| pc1 | --pcie-frac 1.0 | 19.7 (91.4, 83.1) / 18.7 (95.0, 82.5) | 24.3 (73.8, 89.0) / 24.3 (76.1, 89.1) | no win (GPU wait +19%) |
| pw4 | --pool-workers 4 | 14.5 (138.8, 85.2) / 14.7 (140.6, 85.3) | 18.0 (115.9, 89.1) / 19.2 (115.5, 89.6) | LOSS -27%/-28% (confirmed) |
| pw8 | --pool-workers 8 | 18.9 (94.2, 83.8) / 19.0 (94.0, 83.8) | 22.5 (79.6, 87.9) / 23.6 (77.0, 88.7) | loss -7%/-12% |
| pw11 | --pool-workers 11 | 19.6 (100.4, 81.6) / 20.7 (80.8, 84.8) | 25.6 (76.0, 88.8) / 26.1 (64.9, 89.3) | CONTROL (=default workers) |
| pw16 | --pool-workers 16 | 19.9 (88.5, 85.2) / 18.5 (100.1, 82.8) | 25.5 (70.7, 90.0) / 25.6 (84.1, 89.6) | no win |
| kv4 | --kv q4_0 | 19.3 (86.9, 84.1) / 20.1 (98.1, 81.5) | 25.4 (67.5, 89.5) / 27.8 (72.8, 90.5) | no speed win; -418 MiB VRAM |
| kv8 | --kv k8v4 | 20.1 (85.3, 84.0) / 20.1 (85.7, 84.0) | 28.5 (70.4, 90.0) / 28.9 (67.3, 90.0) | CONTROL (kv spelling) |
| rs512 | --resident-cpu-mib 512 | 21.1 (81.1, 85.2) / 20.3 (85.3, 83.8) | 26.4 (67.4, 88.9) / 26.9 (69.9, 89.5) | flat (P1 +3.4% r1 - unconfirmed) |
| rs1024 | --resident-cpu-mib 1024 | 19.7 (88.7, 85.3) / 20.7 (81.1, 85.0) | 26.7 (72.6, 90.1) / 26.5 (69.3, 89.5) | flat |
| rs2048 | --resident-cpu-mib 2048 | 19.9 (98.5, 81.6) / 20.3 (83.4, 84.0) | 25.6 (75.7, 88.3) / 13.9 (104.5, 88.6) | flat; MemAvailable ~0.1 GiB |

## Per-knob verdicts

### (a) --pcie-frac auto | 0 | 0.5 | 1.0  -> KEEP auto
Not inert any more, but still not a win. `--pcie-frac 1.0` raises the per-window 'wait for the GPU' to
22.5/22.1 ms (P1) and 21.6/21.3 ms (P2) against 18.7-18.8/18.9-19.4 ms for every other arm - both runs,
reproducible - i.e. the window's device aliases do feed the PCIe branch (pcie_mode auto = the
device_alias() source, never the staging buffer). 0.5 shows a small rise (19.0-19.7). At frac 0.00
(pcie_num=0 -> pcie_ok false) the timing equals the control exactly, so the probe-chosen 0.26 costs
nothing. Throughput: auto P1 21.2/21.0 P2 23.1/26.0 ; 0 -> 19.4/20.5, 25.5/24.7 ; 0.5 -> 19.6/19.9, 24.0/23.6 ;
1.0 -> 19.7/18.7, 24.3/24.3. Every explicit fraction is neutral-to-worse than auto.

### (b) ZFS ARC trim + --resident-cpu-mib 512 | 1024 | 2048  -> NO WIN, keep 1024 (and leave ARC at 1.5 GiB)
ARC cap was 1610612736 (1.5 GiB, at size 1.65 GiB on entry). With it trimmed to 536870912 (512 MiB) and
drop_caches before each of the three resident arms:
  512  MiB: P1 21.1/20.3  P2 26.4/26.9 ; run-end MemAvailable 2844-4051 MiB
  1024 MiB: P1 19.7/20.7  P2 26.7/26.5 ; run-end MemAvailable  913-2310 MiB
  2048 MiB: P1 19.9/20.3  P2 25.6/13.9*; run-end MemAvailable  102-4465 MiB (*contended run)
The host tier is flat (all inside the identical-config spread), and so is the ARC trim itself: the
shipped-config control (no trim) gives P1 21.2/21.0, P2 23.1/26.0. MemAvailable is the real effect -
trimming ARC to 512 MiB buys ~1 GiB, while --resident-cpu-mib 2048 pushed MemAvailable to 102 MiB with
512 MiB ARC already applied (swap 509 MiB touched) and bought nothing. The 1 GiB:2 GiB host tier is not
on the decode critical path: 'stage 0' host staging is 0.06-0.08 ms/window for all 13 arms.

### (c) --kv q4_0 vs k8v4 at 131072 context -> NO SPEED WIN; q4_0 is a memory lever
q4_0: P1 19.3/20.1  P2 25.4/27.8 (pool 67-98 ms, hit 81.5-90.5). k8v4 (=shipped): P1 20.1/20.1
P2 28.5/28.9. Pooled vs the k8v4/pw11/pca control: P1 -3.5%, P2 +1.1% - inside the noise floor.
What q4_0 does change is VRAM: `expert cache auto: 15.30 GiB free -> 5891 slots` vs `14.89 GiB -> 5726`
at startup, and 7703 filled slots / 14956 MiB vs 7487 / 14538 at runtime, i.e. +418 MiB of experts
resident. No correctness/speed argument for switching; a memory-pressure argument in its favour.

### (d) --pool-workers 4 | 8 | 11 | 16 -> KEEP the default (11 = every physical core)
  4 : P1 14.5/14.7  P2 18.0/19.2 - a CONFIRMED -27%/-28%, stage-0 pool 138.8/140.6 (P1) and
      115.9/115.5 (P2) vs 65-100 control. Both runs agree to 1%.
  8 : P1 18.9/19.0  P2 22.5/23.6 - -7%/-12%, pool 94 ms (P1).
 11 : P1 19.6/20.7  P2 25.6/26.1 - the default, best of the four.
 16 : P1 19.9/18.5  P2 25.5/25.6 - neutral/slightly worse, pool up to 100 ms.
The decode budget is CPU-pool dominated (pool+plan 65-100 ms of the ~90-120 ms window), so worker
count is the one knob that actually moves it, and the engine already defaults to the optimum.

## Flags (>3%)
* rs512 P1 21.1 tok/s (+3.4% vs the 20.41 pooled control) - run 1 only; the identical-config control
  pca-1 also gave 21.2. NOT CONFIRMED, needs a quiet box.
* kv4 P2 27.8 tok/s (+6.1%) - run 2 only, and kv8 (=control) gave 28.5/28.9. NOT CONFIRMED.
* Confirmed (negative) effect: --pool-workers 4, -27/-28%, both runs, all prompts.

## Method notes / caveats
* The harness ran on its own port (:8099, unit ab8-gen, /data/ab8q.py + /data/ab8-serve.sh) after a
  co-tenant's `systemctl stop strata-ab` killed an arm at 15:25:20 while this batch held the GPU lock.
  Final arms therefore cannot collide with :8080 or with the shared `strata-ab` unit.
  Later 4 re-runs use a contention gate: re-run until 'pool + plan' <= 110 ms in the last two stage-0 lines.
* One arm log (/data/strata-src/strata-ab5-pca-1.log) also contains 6 foreign records of 4342 tokens that
  another agent's harness appended; the parse selects by prompt size (4292/3514) and takes the LAST match.
* Nothing was changed in the engine, the config files, /optane or the kernel. The ARC cap is restored to
  1610612736 and tiberius-strata is left running with its original store config.