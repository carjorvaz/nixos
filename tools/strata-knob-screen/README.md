# strata knob screen (port-8099 A/B)

Counterbalanced driver for the knobs the v0.2.20 pin put on the table. It runs its own
server + engine per `(arm, rep)` on an isolated port, reads the per-request record the serve
layer keeps in `GET /metrics`, and writes a summary with paired deltas against the control of
the same rep. The rules it implements are the plan's: 5 counterbalanced runs (3 is the
minimum), **no magnitude bar** - a reproducible positive effect is adoptable however small,
because small wins compound - mean with [min-max], and answer sha per cell.

It is deliberately stdlib-only Python: no venv, no pip, runs on tiberius as-is.

## Safety

* Its own port (default 8099), its own cwd, `--slot-save-path`, sessions, and its own park and
  spill dirs under `--workdir` (default `/data/knob-screen-<stamp>`). The deployed config's
  `--conversation-park-dir` is retargeted at the workdir in every run: a second engine on the
  production `parks/` folder could clobber the parked conversations the service would restore.
  Budget disk for the tiers (`--conversation-park-mib 6144` + `--conversation-spill-mib 8192`
  caps; a 26k park is ~0.5 GiB, the fill conversations in persist mode add up). The config's
  `log` (the production engine log) is likewise retargeted, so each run has its own
  `logs/<arm>-<rep>.engine.log` and nothing is appended to `/persist/strata/strata-general.log`.
* Refuses to start if port 8099 is taken, or if the production engine answers on 8081 --
  pass `--allow-production` to acknowledge and `--stop-unit tiberius-strata` to free the GPU.
  The unit is **started again on exit** (atexit + signal handlers); a SIGKILL of the harness
  bypasses that, so run it from tmux/screen and check `systemctl status tiberius-strata` after.
* It never builds or deploys. Point `--engine-bin` / `--server-py` at the build you want to
  screen; the deployed JSON is only a template (`exe`, `cwd` are retargeted in a copy).

## Paths (from the deployed unit)

```sh
systemctl cat tiberius-strata      # ExecStart shows python, server.py, --config
systemctl show tiberius-strata -p Environment   # the measured STRATA_* knobs
```

The deployed knobs are on the unit's `Environment=`, not in the config JSON, so `--unit-env
tiberius-strata` is not optional in practice: without it the screen would run the arms against
a *different* configuration (the warning on startup is a stop sign). `--base-env KEY=VALUE` is
still there for an extra override; it wins over the unit's value.

For the 0.2.20 screen: build the pin first (on tiberius, natively -- the store artifact from a
remote builder carries that builder's `-march`), then pass the new package's
`share/strata/serve/server.py`, `bin/strata`, and the module's `--config` JSON.

## Smoke test first (one arm, one rep, one cell)

```sh
sudo python3 knob_screen.py \
    --python /nix/store/...-python3-.../bin/python3 \
    --server-py /nix/store/<new>/share/strata/serve/server.py \
    --engine-bin /nix/store/<new>/bin/strata \
    --config /nix/store/...-strata-general.json \
    --unit-env tiberius-strata \
    --workdir /data/knob-screen-smoke \
    --stop-unit tiberius-strata --allow-production \
    --arms control,verify_device_hits --reps 1 --cells p1
```

Read the run's `summary.md` and the engine line in `logs/control-0.log`. If the harness itself
misbehaves (a path, a readiness race), fix that before spending a full run.

## Full screen

```sh
sudo python3 knob_screen.py \
    --python /nix/store/...-python3-.../bin/python3 \
    --server-py /nix/store/<new>/share/strata/serve/server.py \
    --engine-bin /nix/store/<new>/bin/strata \
    --config /nix/store/...-strata-general.json \
    --unit-env tiberius-strata \
    --workdir /data/knob-screen-$(date +%Y%m%d-%H%M) \
    --stop-unit tiberius-strata --allow-production \
    --compare-bin /nix/store/<deployed-0.2.17>/bin/strata
```

`--compare-bin` adds the **prev_build** arm: the previous package's engine with the same serve
layer and config. That is the pin's own speed delta (new build as control, previous build as
arm; a negative delta means the pin is faster). If the previous engine refuses the new serve
layer's protocol, drop the flag and take the pin's delta from the first production generation
against the recorded gen-121 baseline.

8 arms x 5 reps x 3 cells is ~50-60 minutes wall, dominated by ~40 engine loads (each is a
fresh engine, because the env is fixed at process start). That is a long production window:
split it (`--arms control,prev_build,verify_device_hits` first) if that matters. Prompts are
distinct per cell, so no cell inherits another's prefix; `reused` is recorded as evidence that
held.

## Arms

| arm | knob | what it isolates |
|---|---|---|
| `control` | none | the deployed config, the paired baseline |
| `prev_build` | `--compare-bin` | the previous engine binary, same serve layer/config |
| `verify_device_hits` | `STRATA_VERIFY_DEVICE_HITS=1` | on-device verify-window hit planning (bitwise exact) |
| `l3_pf` | `STRATA_L3_PF=1` | static CPU slices + next-layer L3 expert prefetch |
| `pool_static` | `STRATA_POOL_STATIC=1` | the static slices alone (scheduling half of the above) |
| `pin_frac` | `STRATA_CACHE_PIN_FRAC=0.25` | profile-head slots pinned against eviction |
| `q8_inplace` | `STRATA_Q8_INPLACE=1` | dense Q8_0 matrices packed in place (VRAM back to slots) |
| `dense_i8_off` | `STRATA_DENSE_I8_TC=0` + `STRATA_PREFILL_DENSE_I8_TC=0` | disables 0.2.20's default dense INT8 TC (CC>=75) |
| `renorm` | `STRATA_ROUTE_TAIL_RENORM=1` | answer-changing; quality gate, not throughput |

### Revisit / bisect arms (2026-11-23 session sweep)

Added after sweeping the DSH session history for small or untested knobs the old +4 % gate left
behind (`docs/exec-plans/active/strata-revisit-queue.md`):

| arm | knob | measured (5 reps) |
|---|---|---|
| `df2_ctx_batch_off` | `STRATA_DF2_CTX_BATCH=0` | neutral (+0.4 %/+0.1 %) |
| `df2_fork_off` | `STRATA_DF2_FORK=0` | neutral (+0.2 %/-0.0 %) |
| `side_mixer` | `STRATA_SIDE_MIXER=2` | no win (+0.2 %/+0.0 %), answers differ |
| `pf_group_scratch` | `STRATA_PF_GROUP_SCRATCH=1` + `STRATA_PF_HC_REGION=1` | read +1.7/+2.9 % but decode -1.0 %/-10.7 % -> reject |
| `adapt_old_defaults` | `--adapt-every 4 --adapt-swaps 96 --adapt-decay 0.70` | -5.7 %/-5.9 % -> the pin's gain is #4870 |

`dense_i8_off` is a control, not a candidate: a **negative** delta means 0.2.20's default is a
win. If the pack has no eligible dense type the arm is a no-op, and that is the answer (nothing
to measure).

## Decision rule (no magnitude bar)

Adoption is decided by reproducibility, not size: **ADOPT** when every paired rep has the same
sign (5/5), **CANDIDATE** at 4/5 (owner call), answers identical for exact arms. A +0.8% win in
5/5 runs is adoptable; a +4% mean from a 3/5 sign is not. 5 reps is the default because 3 cannot
resolve sub-2% effects (the plan's own caveat); use `--reps 5` for anything you expect to be
small. The read delta is reported and called out when it is worse than -1.5%, but it is not a
veto - a decode win with a prompt cost is your call.

## Persist mode (robustness, not speed)

```sh
sudo python3 knob_screen.py ... --mode persist --persist-fill 6 --reps 2
```

Fills the conversation cache with 6 distinct 26k conversations, restarts the engine, and
repeats one. Control should reuse ~0; with `--conversation-spill-persist` + a persistent
`--conversation-spill-dir` the repeat should reuse a prefix. The tier only writes when the RAM
cache evicts or a capture is refused -- if the log shows no spill lines the test is
inconclusive, not negative: raise `--persist-fill`.

## Evidence and what to do with it

`manifest.json` (argv, script/config sha256, arms and their env, cells, the unit-env keys
applied), `results.json` (one record per run/cell, including the engine start line),
`summary.md`, `logs/*.log`, `config/*.json`, `prompts/*.txt`; a failed arm goes to
`failures.json` and the screen keeps going. Copy the summary's numbers and the evidence path
into `docs/VALIDATION.md` (public-safe: numbers and public flag names only); record the adopted
arm in `profiles/nixos/strata.nix` with the measurement comment convention already used there.

## Limits

* Throughput only. `renorm` and any answer-changing arm need the eval320/needle/repetition
  harness on the box (`/data/eval320`), not this script.
* The cells are synthetic prose sized by `--chars-per-token` (4.3 for this word list; the 7.8
  figure from past campaigns was summary text); the recorded `prompt_tokens` is the truth and is
  compared across arms. Real-traffic mixes are the
  campaign's job, not a knob screen's.
* One request at a time. The batch engine and the lease proxy are out of scope.
