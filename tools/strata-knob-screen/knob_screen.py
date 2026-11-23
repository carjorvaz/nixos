#!/usr/bin/env python3
"""Counterbalanced A/B screen for Strata engine knobs on the isolated port-8099 engine.

Why this exists
---------------
The pin bump (pkgs/strata-sm75) is a perf event by itself: upstream moves defaults, and this
lane runs an engine nobody upstream measures (sm_75, mmap experts from the Optane).  The plan's
rule is that a knob is adopted on counterbalanced evidence, never on one run
(docs/exec-plans/active/strata-tuning-next.md, "Acceptance criteria").  This script is the
driver for that rule: it starts its own server + engine per (arm, rep), runs the same cells,
reads the per-request record the serve layer keeps in GET /metrics, and emits a summary with
paired deltas against the control of the same rep.

It never touches the production service or its state:
  * its own port (default 8099), its own cwd, slot-save path, park/session dirs under --workdir;
  * its own engine config copy (the deployed JSON with `exe`/`cwd` retargeted at the build
    under test, and the arm's flags appended to `user_args`);
  * refuses to start while the production engine's port is open unless --allow-production.

Arms (env-only unless noted):
  control              - the deployed configuration, no extra env (the paired baseline)
  verify_device_hits   - STRATA_VERIFY_DEVICE_HITS=1: plan the verify window's resident hit
                         groups on the device (bitwise exact; upstream's own default on
                         sm_86/89/120 above 16 GiB, not on sm_75)
  l3_pf                - STRATA_L3_PF=1: static CPU row slices + next-layer expert prefetch
                         into L3 while the GPU works (upstream auto-enables only <= 13 GiB)
  pool_static          - STRATA_POOL_STATIC=1: the static slices alone (isolates the schedule
                         from the prefetch)
  pin_frac             - STRATA_CACHE_PIN_FRAC=0.25: pin the profile head against eviction
                         (upstream only auto-pins below 25% resident; this lane is ~37%)
  q8_inplace           - STRATA_Q8_INPLACE=1: pack eligible dense Q8_0 matrices in place
                         (+0 MiB VRAM; a no-op when the pack has no eligible matrices)
  dense_i8_off         - STRATA_DENSE_I8_TC=0 + STRATA_PREFILL_DENSE_I8_TC=0: disables the
                         0.2.20 default (dense INT8 tensor cores are ON for CC >= 75).  A
                         NEGATIVE delta here means the new default is a win; it is the
                         control arm for the pin itself.
  renorm               - STRATA_ROUTE_TAIL_RENORM=1: answer-changing by construction (the
                         partner of the deployed STRATA_ROUTE_TAIL_SKIP=7).  NOT a throughput
                         arm - it belongs to the quality gate; the summary marks it so.

Modes:
  throughput (default) - the arms above, 3 counterbalanced reps, cells p1/p2/llive
  persist              - --conversation-spill-persist: fill the conversation cache, restart
                         the engine, and check the repeat's reused tokens (> 0 means the
                         spill tier survived; control should be 0).  Robustness, not perf.

Usage (on tiberius; paths come from `systemctl cat tiberius-strata`):
  python3 knob_screen.py \
      --python /nix/store/...-python3/bin/python3 \
      --server-py /nix/store/<new-strata>/share/strata/serve/server.py \
      --engine-bin /nix/store/<new-strata>/bin/strata \
      --config /nix/store/...-strata-general.json \
      --unit-env tiberius-strata \
      --workdir /data/knob-screen-$(date +%Y%m%d-%H%M) \
      --stop-unit tiberius-strata

  Start small: --arms control,verify_device_hits --reps 1 --cells p1 first, to prove the
  harness; then the full run.  `--dry-run` prints the plan without starting anything;
  `--self-test` checks the parsing/summary math with synthetic data (no engine).

Evidence layout under --workdir:
  manifest.json        argv, script sha256, config sha256, arms, cells, host
  results.json         one record per (arm, rep, cell)
  summary.md           per-arm paired deltas, verdicts, answer-sha comparisons
  logs/<arm>-<rep>.log server + engine stderr (the engine start line lives here)
  config/<arm>-<rep>.json  the exact engine config used
  prompts/*.txt        the cells' prompts (identical across arms)
"""

from __future__ import annotations

import argparse
import atexit
import hashlib
import json
import os
import random
import re
import shlex
import signal
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

# --------------------------------------------------------------------------------------- arms

ARMS = {
    "control": {
        "env": {},
        "args": [],
        "answer_changing": False,
        "invert": False,
        "why": "the deployed configuration, no extra env",
    },
    "verify_device_hits": {
        "env": {"STRATA_VERIFY_DEVICE_HITS": "1"},
        "args": [],
        "answer_changing": False,
        "invert": False,
        "why": "on-device planning of the verify window's resident hits (host flag spins off the decode path)",
    },
    "l3_pf": {
        "env": {"STRATA_L3_PF": "1"},
        "args": [],
        "answer_changing": False,
        "invert": False,
        "why": "static CPU row slices + next-layer expert prefetch into L3 during the GPU wait",
    },
    "pool_static": {
        "env": {"STRATA_POOL_STATIC": "1"},
        "args": [],
        "answer_changing": False,
        "invert": False,
        "why": "the static row slices alone (scheduling half of STRATA_L3_PF)",
    },
    "pin_frac": {
        "env": {"STRATA_CACHE_PIN_FRAC": "0.25"},
        "args": [],
        "answer_changing": False,
        "invert": False,
        "why": "pin the profile head against eviction (upstream auto-pins only under 25% resident)",
    },
    "q8_inplace": {
        "env": {"STRATA_Q8_INPLACE": "1"},
        "args": [],
        "answer_changing": False,
        "invert": False,
        "why": "eligible dense Q8_0 matrices packed in place (VRAM back to the expert cache)",
    },
    "dense_i8_off": {
        "env": {"STRATA_DENSE_I8_TC": "0", "STRATA_PREFILL_DENSE_I8_TC": "0"},
        "args": [],
        "answer_changing": False,
        "invert": True,
        "why": "disables the 0.2.20 default (dense INT8 TC on CC>=75): a negative delta means the default helps",
    },
    "prev_build": {
        "env": {},
        "args": [],
        "answer_changing": False,
        "invert": False,
        "compare": True,
        "engine_bin": None,   # filled from --compare-bin
        "why": "the PREVIOUS package's bin/strata with the same config and serve layer (the pin's own delta)",
    },
    "persist": {
        "env": {},
        "args": [],
        "answer_changing": False,
        "invert": False,
        "why": "restart test only: --conversation-spill-persist + a persistent spill dir (injected per run)",
    },
    # Revisit/bisect arms from the 2026-11-23 session sweep (the old +4% gate's
    # left-behinds and the untested DFlash2 toggles).  The bisect arms ask which
    # 0.2.20 default explains the pin's +4.7/+6.2% decode; the revisit arms were
    # once seen at +1.3-1.6% inside a one-run spread.
    "df2_ctx_batch_off": {
        "env": {"STRATA_DF2_CTX_BATCH": "0"},
        "args": [], "answer_changing": False, "invert": False,
        "why": "bisect: 0.2.20's default-on DFlash2 context batching off",
    },
    "df2_fork_off": {
        "env": {"STRATA_DF2_FORK": "0"},
        "args": [], "answer_changing": False, "invert": False,
        "why": "bisect: DFlash2 context update / block front on one stream",
    },
    "side_mixer": {
        "env": {"STRATA_SIDE_MIXER": "2"},
        "args": [], "answer_changing": False, "invert": False,
        "why": "revisit: window graph branches (bitwise), +1.4/+1.3% once, -3.1% at 26k",
    },
    "pf_group_scratch": {
        "env": {"STRATA_PF_GROUP_SCRATCH": "1", "STRATA_PF_HC_REGION": "1"},
        "args": [], "answer_changing": False, "invert": False,
        "why": "revisit: frees 0.3-0.5 GiB of borrowed prompt buffers (same bits), more expert slots",
    },
    "adapt_old_defaults": {
        # Pin the pre-0.2.20 adaptive defaults explicitly, which stops #4870's
        # mid-coverage rule (every 4 -> 2, swaps 96 -> 192, decay 0.70 -> 0.92 at
        # 15-65% coverage) from overriding them.  This is the direct bisect of the
        # pin's decode gain: the deployed config sets none of the three, so the
        # rule is what changed at this lane's 36.9%.
        "env": {},
        "args": ["--adapt-every", "4", "--adapt-swaps", "96", "--adapt-decay", "0.70"],
        "answer_changing": False, "invert": False,
        "why": "bisect: pin the old adaptive defaults (disables #4870 mid-coverage)",
    },
    # Queue window 2 (docs/exec-plans/active/strata-revisit-queue.md): the
    # bitwise drafter-GEMM variants, the suffix-draft widths, the draft stream's
    # priority and the aux-thread placement.
    "df2_gemm_off": {
        "env": {"STRATA_DF2_GEMM": "0"},
        "args": [], "answer_changing": False, "invert": False,
        "why": "bitwise drafter GEMM: 0 = 8 rows a warp (the old layout), 1 = rows by size",
    },
    "suffix_draft2": {
        "env": {}, "args": ["--suffix-draft", "2"],
        "answer_changing": False, "invert": False,
        "why": "prompt-lookup suffix threshold 2 (default 3; 2/4/6 never swept)",
    },
    "suffix_draft4": {
        "env": {}, "args": ["--suffix-draft", "4"],
        "answer_changing": False, "invert": False,
        "why": "prompt-lookup suffix threshold 4 (default 3)",
    },
    "df2_prio_off": {
        "env": {"STRATA_DF2_PRIO": "0"},
        "args": [], "answer_changing": False, "invert": False,
        "why": "draft stream priority off (CUDA high-priority stream is the default)",
    },
    "aux_cpus": {
        "env": {"STRATA_AUX_CPUS": "auto"},
        "args": [], "answer_changing": False, "invert": False,
        "why": "aux threads off the engine's cores (the 5.6% host-thread wait; expected <=1-2%)",
    },
    # Queue window 3.
    "park_ram": {
        "env": {"STRATA_DF2_LOG_MIB": "64"},
        "args": ["--prompt-cache", "3"],
        "answer_changing": False, "invert": False,
        "why": "host RAM: 3 prompt checkpoints (not 6) + 64 MiB DFlash2 stash -> park admission",
    },
    "kv_k8v4": {
        "env": {}, "args": ["--kv", "k8v4"],
        "answer_changing": True, "invert": False,
        "why": "KV precision: K int8 + V rotated Q4_0 (-23% KV bytes); quality-gated",
    },
    "prior_1_15": {
        "env": {"STRATA_ROUTE_PRIOR": "1.15"},
        "args": [], "answer_changing": True, "invert": False,
        "why": "routing intervention strength 1.15 (deployed 1.2); quality-gated",
    },
    "prior_1_25": {
        "env": {"STRATA_ROUTE_PRIOR": "1.25"},
        "args": [], "answer_changing": True, "invert": False,
        "why": "routing intervention strength 1.25 (deployed 1.2); quality-gated",
    },
    # Last, low-expected-value sweep (revisit-queue items 9-11).  A 3-rep screen:
    # any sign needs a 5-rep confirmation before it is believed.
    "kv_grow_step": {
        "env": {"STRATA_KV_GROW_STEP": "16384"}, "args": [],
        "answer_changing": False, "invert": False,
        "why": "KV grow quantum doubled (default 8192); fewer, larger grows",
    },
    "prefill_equal": {
        "env": {"STRATA_PREFILL_EQUAL": "1"}, "args": [],
        "answer_changing": True, "invert": False,
        "why": "older equal-cut prompt rule (changes rounding)",
    },
    "cpu_ymm": {
        "env": {"STRATA_CPU_YMM": "1"}, "args": [],
        "answer_changing": True, "invert": False,
        "why": "256-bit CPU expert rows instead of the 512-bit tier (last-bit differences)",
    },
    "pool_spin_off": {
        "env": {"STRATA_POOL_SPIN_US": "0"}, "args": [],
        "answer_changing": False, "invert": False,
        "why": "CPU pool spin disabled (test knob; wake latency)",
    },
    "lookahead_6": {
        "env": {"STRATA_LOOKAHEAD_K": "6"}, "args": [],
        "answer_changing": False, "invert": False,
        "why": "router lookahead depth 6 (default 10); less host work per layer",
    },
    # #4870 parameter sweep: the new default is 2 / 192 / 0.92 at 15-65%
    # coverage.  Explicit flags set the *_given switches and stop the rule from
    # overriding them, so control (no flags, rule) vs these arms isolates the
    # cadence/swap/decay surface the pin proved sensitive.
    "adapt_1_192_92": {
        "env": {}, "args": ["--adapt-every", "1", "--adapt-swaps", "192", "--adapt-decay", "0.92"],
        "answer_changing": False, "invert": False,
        "why": "#4870 sweep: adapt every token",
    },
    "adapt_2_288_92": {
        "env": {}, "args": ["--adapt-every", "2", "--adapt-swaps", "288", "--adapt-decay", "0.92"],
        "answer_changing": False, "invert": False,
        "why": "#4870 sweep: 50% more swaps per plan",
    },
    "adapt_2_192_95": {
        "env": {}, "args": ["--adapt-every", "2", "--adapt-swaps", "192", "--adapt-decay", "0.95"],
        "answer_changing": False, "invert": False,
        "why": "#4870 sweep: slower credit decay (keep hot experts longer)",
    },
    "adapt_3_160_88": {
        "env": {}, "args": ["--adapt-every", "3", "--adapt-swaps", "160", "--adapt-decay", "0.88"],
        "answer_changing": False, "invert": False,
        "why": "#4870 sweep: lighter cadence, fewer swaps, faster decay",
    },
    "adapt_1_192_95": {
        "env": {}, "args": ["--adapt-every", "1", "--adapt-decay", "0.95"],
        "answer_changing": False, "invert": False,
        "why": "#4870 sweep 2: every-token cadence + slower decay (the two winners combined)",
    },
    "adapt_1_160_95": {
        "env": {}, "args": ["--adapt-every", "1", "--adapt-swaps", "160", "--adapt-decay", "0.95"],
        "answer_changing": False, "invert": False,
        "why": "#4870 sweep 2: every-token cadence, fewer swaps, slower decay",
    },
    "tail_skip8": {
        "env": {"STRATA_ROUTE_TAIL_SKIP": "8"},
        "args": [], "answer_changing": True, "invert": False,
        "why": "skip rank-8 missed experts too (deployed is 7); quality-gated, answer-changing",
    },
    "renorm": {
        "env": {"STRATA_ROUTE_TAIL_RENORM": "1"},
        "args": [],
        "answer_changing": True,
        "invert": False,
        "why": "answer-changing: the partner of the lossy tail-skip default; quality gate, not throughput",
    },
}

# Cell name -> prompt size in tokens (chars are derived with --chars-per-token).  Distinct
# prompts per cell: no cell may reuse another's prefix, and `reused` is recorded as evidence.
CELLS = [("p1", 4252), ("p2", 3477), ("llive", 26134), ("xlive", 38000)]

WORDS = (
    "harbor ledger quartz meadow lantern copper river silently narrow winter fabric marble "
    "garden orchard tunnel beacon cinder valley pepper anchor basket hollow prairie saddle "
    "timber meadow granite pelican compass fable ripple saffron thistle umbrella vessel "
    "window yellow zephyr almond bramble canyon drizzle ember fathom gravel heron ivory "
    "juniper kettle lattice mitten nugget oyster pebble quiver rafter stencil tundra "
    "upper vivid willow xenon yarrow zinnia amber basalt cobalt dune elm flint grove "
    "hazel inlet jetty knoll loam moss nook opal pine quill reed shale tide umber vine "
    "wren yard zenith acorn birch cedar dock elder fern gully heath iris junco kelp"
).split()


# ------------------------------------------------------------------------------------ helpers


def unit_env(unit: str) -> dict:
    """The unit's Environment= (the measured STRATA_* knobs) as a dict.

    systemd prints KEY=VALUE pairs, quoting values with spaces; the module's values are simple
    (numbers, paths), so shlex is enough.  Without these the screen would test a different
    configuration from the deployed one -- the arms would be the only env present.
    """
    try:
        raw = subprocess.check_output(
            ["systemctl", "show", "-p", "Environment", "--value", unit], text=True, timeout=20
        ).strip()
    except (OSError, subprocess.SubprocessError) as exc:
        raise SystemExit(f"--unit-env {unit}: cannot read the unit environment ({exc})") from exc
    env = {}
    for token in shlex.split(raw):
        key, sep, value = token.partition("=")
        if sep and key:
            env[key] = value
    return env


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:16]


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def synthetic_text(tokens: int, seed: int, chars_per_token: float) -> str:
    """Deterministic prose of roughly `tokens` tokens; the recorded prompt_tokens is the truth."""
    rnd = random.Random(seed)
    target = max(64, int(tokens * chars_per_token))
    sentences = []
    size = 0
    while size < target:
        n = rnd.randint(12, 18)
        sentence = " ".join(rnd.choice(WORDS) for _ in range(n)).capitalize() + "."
        sentences.append(sentence)
        size += len(sentence) + 1
    return " ".join(sentences)


def http_json(url: str, payload=None, timeout: float = 600.0, api_key: str = ""):
    data = None
    headers = {"Accept": "application/json"}
    if payload is not None:
        data = json.dumps(payload).encode()
        headers["Content-Type"] = "application/json"
    if api_key:
        headers["Authorization"] = "Bearer " + api_key
    req = urllib.request.Request(url, data=data, headers=headers, method="POST" if data else "GET")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        body = resp.read()
    return json.loads(body.decode() or "{}")


def port_open(host: str, port: int, timeout: float = 1.0) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.settimeout(timeout)
        return s.connect_ex((host, port)) == 0


def wait_port_free(host: str, port: int, timeout: float) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if not port_open(host, port):
            return
        time.sleep(0.5)
    raise SystemExit(f"port {host}:{port} is still in use after {timeout:.0f}s")


# ------------------------------------------------------------------------------------- engine


class Engine:
    """One isolated server+engine process for one (arm, rep)."""

    def __init__(self, cfg: dict, args, arm: str, rep: int, workdir: Path):
        self.args = args
        self.arm = arm
        self.rep = rep
        self.workdir = workdir
        self.host = args.host
        self.port = args.port
        self.proc = None
        self.log_path = workdir / "logs" / f"{arm}-{rep}.log"
        self.engine_log_path = workdir / "logs" / f"{arm}-{rep}.engine.log"
        self.config_path = workdir / "config" / f"{arm}-{rep}.json"
        self.log_fh = None
        self.cfg = self._prepare_config(cfg)

    @staticmethod
    def _set_arg(out: dict, flag: str, value: str) -> None:
        """Replace (or add) one engine flag in args/user_args, so every run owns its paths."""
        for key in ("args", "user_args"):
            src = list(out.get(key) or [])
            cleaned = []
            i = 0
            while i < len(src):
                if src[i] == flag:
                    i += 2          # drop the flag and the value that follows it
                    continue
                cleaned.append(src[i])
                i += 1
            out[key] = cleaned
        out.setdefault("user_args", [])
        out["user_args"] += [flag, str(value)]

    def _isolate_state(self, out: dict) -> None:
        """Keep the pmem park tier and the SSD spill tier out of the deployed data folder.

        The deployed config points --conversation-park-dir at <dataDir>/parks; a second engine on
        the same folder can clobber the parked conversations the service would restore.  Both
        tiers get a directory under --workdir, removed or kept with the evidence.
        """
        self._set_arg(out, "--conversation-park-dir", self.workdir / "parks")
        self._set_arg(out, "--conversation-spill-dir", self.workdir / "spill")
        (self.workdir / "parks").mkdir(parents=True, exist_ok=True)
        (self.workdir / "spill").mkdir(parents=True, exist_ok=True)

    def _retarget_package_paths(self, out: dict, old_root: str) -> None:
        """Point the data files the config names at the build under test, not the deployed one.

        The config carries absolute store paths for the package's own data (--expert-profile) and
        its cwd; testing a new package with the old profile would mix builds.  --pack/--native
        live under the data dir and are deliberately left alone.
        """
        new_root = str(Path(self.args.server_py).resolve().parent.parent) if self.args.server_py else ""
        if not old_root or not new_root or old_root == new_root:
            return
        prefix = old_root.rstrip("/") + os.sep
        for key in ("args", "user_args"):
            out[key] = [
                new_root + value[len(old_root):] if isinstance(value, str) and value.startswith(prefix) else value
                for value in (out.get(key) or [])
            ]

    def _prepare_config(self, cfg: dict) -> dict:
        out = json.loads(json.dumps(cfg))  # deep copy
        self._retarget_package_paths(out, str(cfg.get("cwd") or ""))
        self._isolate_state(out)
        out["log"] = str(self.engine_log_path)   # not /persist/strata/strata-general.log
        # child_env() in serve/server.py starts from the process env and then applies cfg["env"],
        # so an arm that collided with a pinned config value would silently lose.  Put the arm's
        # values in the config copy too; that also makes the exact engine env evidence.
        arm_env = ARMS[self.arm]["env"]
        cfg_env = out.setdefault("env", {})
        for key, value in arm_env.items():
            if key in cfg_env and str(cfg_env[key]) != value:
                print(f"    note: arm {self.arm} overrides config env {key}={cfg_env[key]} -> {value}", flush=True)
            cfg_env[key] = value
        arm_bin = ARMS[self.arm].get("engine_bin") or self.args.engine_bin
        if arm_bin:
            out["exe"] = str(Path(arm_bin).resolve())
        if self.args.server_py:
            out["cwd"] = str(Path(self.args.server_py).resolve().parent.parent)
        arm = ARMS[self.arm]
        if arm["args"]:
            out.setdefault("user_args", [])
            out["user_args"] = list(out["user_args"]) + list(arm["args"])
        self.config_path.parent.mkdir(parents=True, exist_ok=True)
        self.config_path.write_text(json.dumps(out, indent=2) + "\n")
        return out

    def start(self) -> None:
        self.log_path.parent.mkdir(parents=True, exist_ok=True)
        self.log_fh = open(self.log_path, "wb")
        cmd = [
            self.args.python,
            str(Path(self.args.server_py).resolve()),
            "--engine",
            "strata",
            "--config",
            str(self.config_path),
            "--host",
            self.host,
            "--port",
            str(self.port),
            "--slot-save-path",
            str(self.workdir / "sessions"),
        ]
        env = dict(os.environ)
        env.update(self._base_env())
        env.update(ARMS[self.arm]["env"])
        env.setdefault("STRATA_NO_WEB", "1")
        env["PYTHONUNBUFFERED"] = "1"
        cwd = self.cfg.get("cwd") or str(Path(self.args.server_py).resolve().parent.parent)
        (self.workdir / "sessions").mkdir(parents=True, exist_ok=True)
        self.proc = subprocess.Popen(
            cmd,
            cwd=cwd,
            env=env,
            stdout=self.log_fh,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        try:
            self._wait_ready()
        except BaseException:
            self.stop()
            raise

    def _base_env(self) -> dict:
        env = dict(getattr(self.args, "unit_env_map", {}) or {})
        for item in self.args.base_env or []:
            key, sep, value = item.partition("=")
            if not sep:
                raise SystemExit(f"--base-env needs KEY=VALUE, got {item!r}")
            env[key] = value
        return env

    def _wait_ready(self) -> None:
        deadline = time.time() + self.args.start_timeout
        last = ""
        while time.time() < deadline:
            if self.proc is not None and self.proc.poll() is not None:
                raise RuntimeError(f"engine exited during start (rc={self.proc.returncode}); see {self.log_path}")
            try:
                health = http_json(f"http://{self.host}:{self.port}/health", timeout=5)
                if isinstance(health, dict) and health.get("status") in ("ok", "ready", None):
                    metrics = http_json(f"http://{self.host}:{self.port}/metrics", timeout=10)
                    if (metrics.get("engine") or {}).get("version"):
                        # a real request proves the engine loop, not just the HTTP server
                        warm = synthetic_text(64, 999, self.args.chars_per_token)
                        remaining = max(5.0, deadline - time.time())
                        self.chat("Warm up. Reply with one short sentence.", 8, timeout=min(60.0, remaining))
                        return
            except (urllib.error.URLError, ConnectionError, ValueError, OSError) as exc:
                last = str(exc)
            time.sleep(2)
        raise RuntimeError(f"engine not ready after {self.args.start_timeout:.0f}s ({last}); see {self.log_path}")

    def stop(self) -> None:
        if self.proc is None:
            return
        try:
            os.killpg(os.getpgid(self.proc.pid), signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            self.proc.wait(timeout=self.args.stop_timeout)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(os.getpgid(self.proc.pid), signal.SIGKILL)
            except ProcessLookupError:
                pass
            self.proc.wait(timeout=15)
        self.proc = None
        if self.log_fh is not None:
            self.log_fh.close()
            self.log_fh = None

    def restart(self) -> None:
        self.stop()
        time.sleep(2)
        wait_port_free(self.host, self.port, self.args.stop_timeout)
        self.start()

    def metrics(self) -> dict:
        return http_json(f"http://{self.host}:{self.port}/metrics", timeout=30, api_key=self.args.api_key)

    def chat(self, prompt: str, max_tokens: int, timeout: float = None) -> dict:
        model = self.cfg.get("model_name") or "strata"
        payload = {
            "model": model,
            "messages": [{"role": "user", "content": prompt}],
            "max_tokens": max_tokens,
            "temperature": 0,
            "stream": False,
        }
        url = f"http://{self.host}:{self.port}/v1/chat/completions"
        try:
            return http_json(url, payload, timeout=timeout or self.args.request_timeout, api_key=self.args.api_key)
        except urllib.error.HTTPError as exc:
            body = exc.read().decode(errors="replace")[:400]
            if exc.code == 400 and "max_completion_tokens" in body:
                payload.pop("max_tokens", None)
                payload["max_completion_tokens"] = max_tokens
                return http_json(url, payload, timeout=timeout or self.args.request_timeout, api_key=self.args.api_key)
            raise RuntimeError(f"HTTP {exc.code}: {body}") from exc

    def engine_start_line(self) -> str:
        """The engine's own start line (provenance: it is authoritative over the driver)."""
        for path in (self.engine_log_path, self.log_path):
            if not path.exists():
                continue
            try:
                text = path.read_text(errors="replace")
            except OSError:
                continue
            for line in text.splitlines():
                # the serve layer writes "[strata] <time> engine started: <exe> --serve <args>";
                # a plain engine build also prints "INFO ... engine=0.1.x".  Either is the
                # authoritative record of what ran, so take the first one.
                if "engine started:" in line or re.search(r"engine=0\.1\.\d+", line):
                    return line.strip()[:500]
        return ""


# ---------------------------------------------------------------------------------- recording


def extract_record(metrics: dict, reply: dict, before_totals: dict) -> dict:
    """The serve layer's per-request record (newest in GET /metrics) plus totals cross-check."""
    records = metrics.get("requests") or []
    usage = reply.get("usage") or {}
    if not records:
        raise RuntimeError("GET /metrics returned no request history")
    rec = records[0]
    if usage and rec.get("output_tokens") != usage.get("completion_tokens"):
        raise RuntimeError(
            f"metrics history does not match the reply (record output={rec.get('output_tokens')!r}, "
            f"reply={usage.get('completion_tokens')!r})"
        )
    totals = metrics.get("totals") or {}
    prompt_ms = rec.get("prompt_ms")
    prompt_read = rec.get("prompt_read")
    read_tok_s = round(prompt_read / (prompt_ms / 1000.0), 1) if prompt_read and prompt_ms else None
    offered = rec.get("drafts_offered")
    accepted = rec.get("drafts_accepted")
    acceptance = round(accepted / offered, 3) if offered and accepted is not None else None
    return {
        "prompt_tokens": rec.get("prompt_tokens"),
        "prompt_read": prompt_read,
        "reused": rec.get("reused"),
        "output_tokens": rec.get("output_tokens"),
        "prompt_ms": prompt_ms,
        "decode_ms": rec.get("decode_ms"),
        "read_tok_s": read_tok_s,
        "decode_tok_s": rec.get("decode_tok_s"),
        "first_engine_token_s": rec.get("first_engine_token_s"),
        "hit_rate": rec.get("hit_rate"),
        "drafts_offered": offered,
        "drafts_accepted": accepted,
        "acceptance": acceptance,
        "file_mb": rec.get("file_mb"),
        "finish": rec.get("finish"),
        "duration_s": rec.get("duration_s"),
        "totals_requests_delta": (totals.get("requests") or 0) - (before_totals.get("requests") or 0),
    }


def run_cell(engine: Engine, cell: str, prompt: str, max_tokens: int) -> dict:
    before = engine.metrics()
    reply = engine.chat(prompt, max_tokens)
    metrics = None
    record = None
    for _ in range(20):  # the history record is appended when the request finishes; usually immediate
        metrics = engine.metrics()
        try:
            record = extract_record(metrics, reply, before.get("totals") or {})
            break
        except RuntimeError:
            time.sleep(0.25)
    if record is None:
        raise RuntimeError(f"no /metrics record appeared for cell {cell}")
    content = ((reply.get("choices") or [{}])[0].get("message") or {}).get("content") or ""
    record.update(
        {
            "cell": cell,
            "answer_sha": sha256_text(content),
            "answer_chars": len(content),
            "answer_head": content[:160].replace("\n", " "),
            "engine_version": (metrics.get("engine") or {}).get("version"),
            "expert_slots": (metrics.get("engine") or {}).get("expert_slots"),
        }
    )
    return record


# ------------------------------------------------------------------------------------ summary


def _mean(values):
    values = [v for v in values if isinstance(v, (int, float))]
    return sum(values) / len(values) if values else None


def _fmt(value, spec=".1f"):
    return format(value, spec) if isinstance(value, (int, float)) else "-"


def summarize(results: list, arms: list, meta: dict) -> str:
    by = {}
    for r in results:
        by.setdefault((r["arm"], r["rep"], r["cell"]), []).append(r)

    cells = meta.get("cells") or []
    lines = ["# Strata knob screen", ""]
    lines.append(f"- date: {meta.get('date')}")
    lines.append(f"- engine: {meta.get('engine_version') or 'unknown'}  (`{meta.get('engine_start_line','')[:180]}`)")
    lines.append(f"- reps: {meta.get('reps')}  arms: {', '.join(arms)}")
    if meta.get("expected") and len(results) < meta["expected"]:
        lines.append(f"- **INCOMPLETE: {len(results)}/{meta['expected']} cell records; see failures.json**")
    lines.append(f"- cells: " + ", ".join(f"{c} ({n} tok)" for c, n in cells))
    lines.append("")
    lines.append("Paired deltas are arm minus control of the SAME rep (so engine-to-engine drift cancels).")
    lines.append("Mean [min-max] over reps. No magnitude bar: adoption is reproducibility (the same sign")
    lines.append("in every paired run); the read delta is reported, not a veto.")
    lines.append("")

    verdicts = []
    for arm in arms:
        if arm == "control":
            continue
        spec = ARMS[arm]
        for cell, _ in cells:
            deltas = []
            shas_equal = True
            read_deltas = []
            prompt_sizes = set()
            for rep in range(meta["reps"]):
                base = by.get(("control", rep, cell), [])
                arr = by.get((arm, rep, cell), [])
                if not base or not arr:
                    continue
                b, a = base[0], arr[0]
                prompt_sizes.add(b.get("prompt_tokens"))
                prompt_sizes.add(a.get("prompt_tokens"))
                if b.get("answer_sha") != a.get("answer_sha"):
                    shas_equal = False
                if b.get("decode_tok_s") and a.get("decode_tok_s"):
                    deltas.append((a["decode_tok_s"] - b["decode_tok_s"]) / b["decode_tok_s"] * 100.0)
                if b.get("read_tok_s") and a.get("read_tok_s"):
                    read_deltas.append((a["read_tok_s"] - b["read_tok_s"]) / b["read_tok_s"] * 100.0)
            if not deltas:
                continue
            mean = _mean(deltas)
            positives = sum(1 for d in deltas if d > 0)
            read_mean = _mean(read_deltas)
            size_ok = len(prompt_sizes) <= 1 or (
                max(prompt_sizes) - min(prompt_sizes) <= 0.05 * (sum(prompt_sizes) / len(prompt_sizes))
            )
            n = len(deltas)
            negatives = n - positives
            strong = (4 * n + 4) // 5          # ceil(0.8 * n)
            if not size_ok:
                verdict = "PROMPT-SIZE-MISMATCH"
            elif n < 3:
                verdict = f"INCONCLUSIVE (n={n}; a decision needs >= 3 paired reps)"
            elif spec.get("compare"):
                # answers may differ across builds by construction; this arm is the pin's speed only
                if negatives == n and mean < 0:
                    verdict = f"PIN-WIN (the new build is {-mean:.1f}% faster; {n}/{n} reps)"
                elif positives == n and mean > 0:
                    verdict = f"PIN-REGRESSION (the previous build is {mean:.1f}% faster; {n}/{n} reps)"
                elif negatives >= strong and mean < 0:
                    verdict = f"PIN-LIKELY-WIN ({-mean:.1f}%; {negatives}/{n} down; owner call)"
                elif positives >= strong and mean > 0:
                    verdict = f"PIN-LIKELY-REGRESSION ({mean:.1f}%; {positives}/{n} up; owner call)"
                else:
                    verdict = "PIN-NEUTRAL"
            elif spec["invert"]:
                # this arm turns a default OFF: the default is a win when the arm loses every rep
                if negatives == n:
                    verdict = "DEFAULT-WIN (the arm lost all reps: the new default is better)"
                elif negatives >= strong:
                    verdict = f"DEFAULT-POSITIVE ({negatives}/{n} reps show the default better; owner call)"
                elif positives == n:
                    verdict = "DEFAULT-HURTS (the new default lost every rep)"
                else:
                    verdict = "DEFAULT-NEUTRAL"
            elif not shas_equal:
                verdict = "ANSWER-CHANGING (quality gate only)"
            else:
                # NO magnitude bar: a reproducible positive effect is adoptable, however small
                if positives == n:
                    verdict = f"ADOPT (+{mean:.1f}%, {n}/{n} reps up, answers identical)"
                elif positives >= strong:
                    verdict = f"CANDIDATE (+{mean:.1f}%, {positives}/{n} reps up; owner call)"
                elif negatives == n and mean < 0:
                    verdict = "REGRESSION"
                elif negatives >= strong and mean < 0:
                    verdict = f"LIKELY-REGRESSION ({mean:.1f}%, {negatives}/{n} down)"
                else:
                    verdict = "NO-WIN"
            # the read delta is reported, not a veto: a decode win with a prompt cost is the owner's call
            if read_mean is not None and read_mean <= -1.5:
                verdict += f" / read {read_mean:+.1f}% (weigh TTFT)"
            verdicts.append((arm, cell, mean, positives, n, read_mean, verdict, shas_equal))
            lines.append(
                f"- **{arm} / {cell}**: decode {mean:+.1f}% "
                f"[{min(deltas):+.1f} .. {max(deltas):+.1f}] ({positives}/{len(deltas)} up)"
                + (f", read {read_mean:+.1f}%" if read_mean is not None else "")
                + ("" if shas_equal else ", ANSWERS DIFFER")
                + f" -> **{verdict}**"
            )
    lines.append("")
    lines.append("## Absolute means (control vs arms)")
    lines.append("")
    lines.append("| arm | cell | decode tok/s | read tok/s | prompt ms | decode ms | acceptance |")
    lines.append("|---|---|---|---|---|---|---|")
    for arm in arms:
        for cell, _ in cells:
            recs = [by[(arm, rep, cell)][0] for rep in range(meta["reps"]) if (arm, rep, cell) in by]
            if not recs:
                continue
            dec = _mean([r.get("decode_tok_s") for r in recs])
            rd = _mean([r.get("read_tok_s") for r in recs])
            pm = _mean([r.get("prompt_ms") for r in recs])
            dm = _mean([r.get("decode_ms") for r in recs])
            ac = _mean([r.get("acceptance") for r in recs])
            lines.append(
                f"| {arm} | {cell} | {_fmt(dec)} | {_fmt(rd, '.0f')} | {_fmt(pm, '.0f')} | "
                f"{_fmt(dm, '.0f')} | {_fmt(ac, '.3f')} |"
            )
    reused = sorted({r.get("reused") for r in results if r.get("reused")})
    if reused and any(v > 0 for v in reused):
        cells_hit = sorted({r.get("cell") for r in results if (r.get("reused") or 0) > 0})
        lines.append("")
        lines.append(f"- **WARNING: `reused` was nonzero ({reused}) on {', '.join(cells_hit)}**: those")
        lines.append("  prompt reads were not fresh; do not read the read/decode numbers for those cells")
        lines.append("  as a prompt-path comparison (the prompts should be distinct per cell).")
    lines.append("")
    lines.append("## Arm map")
    lines.append("")
    for arm in arms:
        if arm == "control":
            continue
        lines.append(f"- `{arm}`: {ARMS[arm]['why']}")
    lines.append("")
    lines.append("## How to read it")
    lines.append("")
    lines.append("- **No magnitude bar** (owner, 2026-11-23): any reproducible positive effect is adoptable,")
    lines.append("  because +1% wins compound.  Reproducibility is the rule that replaced the +4% gate:")
    lines.append("  the same sign in every paired run (ADOPT) or 4/5 (CANDIDATE, owner call), answers")
    lines.append("  identical, and the per-rep spread quoted.  Sub-2% effects need 5 reps: 3 cannot resolve them.")
    lines.append("- The read delta is reported, not a veto; a decode win that costs prompt reads is your call")
    lines.append("  (it is called out when it is worse than -1.5%).")
    lines.append("- REGRESSION: do not deploy; check the engine log for the knob's own line before believing it.")
    lines.append("- ANSWER-CHANGING arms (renorm) go to the quality gate: eval320 not > 8 tasks worse, needle")
    lines.append("  3/3, clean repetition probe.  This table is not a quality verdict.")
    lines.append("- If `reused` was not 0 on a cell, the conversation cache crossed cells: the read numbers are")
    lines.append("  not fresh reads; re-run that cell with distinct prompts.")
    lines.append("")
    return "\n".join(lines)


# ------------------------------------------------------------------------------------ modes


def plan_runs(arms: list, reps: int) -> list:
    """Counterbalanced: even reps control-first, odd reps control-last; the rest rotates."""
    plan = []
    for rep in range(reps):
        rest = [a for a in arms if a != "control"]
        shift = rep % max(1, len(rest))
        order = rest[shift:] + rest[:shift]
        if rep % 2 == 0:
            order = ["control"] + order
        else:
            order = order + ["control"]
        plan.append((rep, order))
    return plan


def run_throughput(engine_args, cfg: dict, workdir: Path, arms: list, reps: int, cells, results: list,
                   failures: list, flush) -> None:
    prompts = {}
    for name, tokens in cells:
        seed = {"p1": 11, "p2": 22, "llive": 33}.get(name, 44)
        prompts[name] = (
            "Summarize the following passage in one paragraph.\n\n"
            + synthetic_text(tokens, seed=seed, chars_per_token=engine_args.chars_per_token)
        )
        (workdir / "prompts").mkdir(parents=True, exist_ok=True)
        (workdir / "prompts" / f"{name}.txt").write_text(prompts[name])

    plan = plan_runs(arms, reps)
    total = sum(len(order) for _, order in plan)
    done = 0
    for rep, order in plan:
        for arm in order:
            done += 1
            print(f"[{done}/{total}] rep {rep} arm {arm}: starting engine", flush=True)
            engine = Engine(cfg, engine_args, arm, rep, workdir)
            try:
                engine.start()
                time.sleep(engine_args.settle)
                start_line = engine.engine_start_line()
                for cell, _ in cells:
                    print(f"    cell {cell}", flush=True)
                    rec = run_cell(engine, cell, prompts[cell], engine_args.max_tokens)
                    rec.update({"arm": arm, "rep": rep, "engine_start_line": start_line})
                    results.append(rec)
                    flush()
            except Exception as exc:  # one bad arm must not take the screen's measurements with it
                failures.append({"arm": arm, "rep": rep, "error": f"{type(exc).__name__}: {exc}"})
                print(f"    FAILED {arm} rep {rep}: {exc}", file=sys.stderr, flush=True)
                flush()
            finally:
                engine.stop()
            wait_port_free(engine_args.host, engine_args.port, engine_args.stop_timeout)


def run_persist(engine_args, cfg: dict, workdir: Path, reps: int, cells, results: list,
                failures: list, flush) -> None:
    """Robustness: does --conversation-spill-persist let a repeat reuse after an engine restart?"""
    tokens = cells[-1][1]
    prompts = [
        "Summarize the following passage in one paragraph.\n\n"
        + synthetic_text(tokens, seed=1000 + i, chars_per_token=engine_args.chars_per_token)
        for i in range(engine_args.persist_fill)
    ]
    target = 1  # repeat one of the filled conversations after the restart
    persist_args = ["--conversation-spill-persist", "--conversation-spill-dir", str(workdir / "spill")]
    arms = [("control", []), ("persist", persist_args)]
    for rep in range(reps):
        for arm, extra in arms:
            # start from the unmodified config, then append this arm's engine flags
            local = json.loads(json.dumps(cfg))
            local.setdefault("user_args", [])
            local["user_args"] = list(local["user_args"]) + extra
            cfg_path = workdir / "config" / f"{arm}-persist-{rep}.json"
            cfg_path.parent.mkdir(parents=True, exist_ok=True)
            cfg_path.write_text(json.dumps(local, indent=2) + "\n")
            engine = Engine(local, engine_args, arm, rep, workdir)
            try:
                engine.start()
                for i, prompt in enumerate(prompts):
                    rec = run_cell(engine, f"fill{i}", prompt, 16)
                    results.append({**rec, "arm": arm, "rep": rep, "phase": "fill",
                                    "engine_start_line": engine.engine_start_line()})
                    flush()
                engine.restart()
                rec = run_cell(engine, "repeat-after-restart", prompts[target], 16)
                results.append({**rec, "arm": arm, "rep": rep, "phase": "repeat",
                                "engine_start_line": engine.engine_start_line()})
                flush()
            except Exception as exc:
                failures.append({"arm": arm, "rep": rep, "error": f"{type(exc).__name__}: {exc}"})
                print(f"    FAILED {arm} rep {rep}: {exc}", file=sys.stderr, flush=True)
                flush()
            finally:
                engine.stop()
            wait_port_free(engine_args.host, engine_args.port, engine_args.stop_timeout)


# ------------------------------------------------------------------------------------- park/eval


def run_park(engine_args, cfg: dict, workdir: Path, arms: list, reps: int, cells, results: list,
             failures: list, flush) -> None:
    """Does the host-RAM arm turn a refused park into an admitted one and reuse on the repeat?"""
    a_prompt = ("Summarize the following passage in one paragraph.\n\n"
                + synthetic_text(engine_args.park_tokens, 707, engine_args.chars_per_token))
    b_prompt = ("Summarize the following passage in one paragraph.\n\n"
                + synthetic_text(engine_args.park_foreign, 808, engine_args.chars_per_token))
    for rep in range(reps):
        for arm in arms:
            engine = Engine(cfg, engine_args, arm, rep, workdir)
            try:
                engine.start()
                time.sleep(engine_args.settle)
                a1 = run_cell(engine, "A1", a_prompt, 32)
                b = run_cell(engine, "B", b_prompt, 16)     # B's start parks A (or refuses)
                a2 = run_cell(engine, "A2", a_prompt, 32)   # restores A's prefix if it was parked
                log = engine.engine_log_path.read_text(errors="replace") if engine.engine_log_path.exists() else ""
                park_lines = []
                for line in log.splitlines():
                    low = line.lower()
                    if "park" in low and any(k in low for k in ("skip parking", "parked", "restor", "admission")):
                        if line.strip() not in park_lines:
                            park_lines.append(line.strip()[:300])
                results.append({**a2, "arm": arm, "rep": rep, "phase": "A2",
                                "a1_prompt_tokens": a1.get("prompt_tokens"),
                                "a1_prompt_ms": a1.get("prompt_ms"), "a1_reused": a1.get("reused"),
                                "b_reused": b.get("reused"),
                                "a2_reused": a2.get("reused"), "park_lines": park_lines[-8:]})
                flush()
            except Exception as exc:
                failures.append({"arm": arm, "rep": rep, "error": f"{type(exc).__name__}: {exc}"})
                print(f"    FAILED {arm} rep {rep}: {exc}", file=sys.stderr, flush=True)
                flush()
            finally:
                engine.stop()
            wait_port_free(engine_args.host, engine_args.port, engine_args.stop_timeout)


def run_eval(engine_args, cfg: dict, workdir: Path, arms: list, reps: int, cells, results: list,
             failures: list, flush) -> None:
    """Start the isolated engine per arm and run the eval script against it (quality gate)."""
    script = engine_args.eval_script
    items = engine_args.eval_items
    if not Path(script).is_file():
        raise SystemExit(f"--eval-script is not a file: {script}")
    if not Path(items).is_file():
        raise SystemExit(f"--eval-items is not a file: {items}")
    for arm in arms:
        engine = Engine(cfg, engine_args, arm, 0, workdir)
        try:
            engine.start()
            cmd = [engine_args.python, script, arm, "--url",
                   f"http://{engine_args.host}:{engine_args.port}", "--items", items,
                   "--max-tokens", str(engine_args.eval_max_tokens)]
            proc = subprocess.run(cmd, capture_output=True, text=True, timeout=engine_args.request_timeout)
            score = None
            for line in proc.stdout.splitlines():
                if line.startswith("SCORE "):
                    score = json.loads(line[6:])
            if score is None:
                raise RuntimeError(f"eval produced no SCORE (rc={proc.returncode}); stderr: {proc.stderr[-300:]}")
            results.append({"arm": arm, "rep": 0, "eval": score,
                            "eval_log": proc.stdout[-4000:],
                            "engine_start_line": engine.engine_start_line()})
            print(f"    {arm}: {score.get('ok')}/{score.get('of')} in {score.get('wall_s')}s", flush=True)
            flush()
        except Exception as exc:
            failures.append({"arm": arm, "rep": 0, "error": f"{type(exc).__name__}: {exc}"})
            print(f"    FAILED {arm}: {exc}", file=sys.stderr, flush=True)
            flush()
        finally:
            engine.stop()
        wait_port_free(engine_args.host, engine_args.port, engine_args.stop_timeout)


def summarize_park(results: list) -> str:
    lines = ["# Host-RAM / park admission test", ""]
    lines.append("| arm | rep | A tokens | A read ms | B reused | A repeat reused | A repeat read ms | park lines |")
    lines.append("|---|---|---|---|---|---|---|---|")
    for r in results:
        admitted = any("skip parking" not in x.lower() for x in r.get("park_lines") or [])
        lines.append(
            f"| {r['arm']} | {r['rep']} | {r.get('a1_prompt_tokens')} | {r.get('a1_prompt_ms')} | "
            f"{r.get('b_reused')} | **{r.get('a2_reused')}** | {r.get('prompt_ms')} | "
            f"{'parked' if admitted else 'refused/unknown'} |"
        )
    lines.append("")
    by = {}
    for r in results:
        by.setdefault(r["arm"], []).append(r)
    lines.append("## Verdict")
    lines.append("")
    lines.append("The win is A's repeat: with a successful park it reuses A's prefix (~all its tokens)")
    lines.append("and the read collapses; refused, it reads A again from token 0.  A 'skip parking' line")
    lines.append("without a later 'parked' one is a refusal.")
    for arm, rs in by.items():
        reused = [r.get("a2_reused") or 0 for r in rs]
        toks = [r.get("a1_prompt_tokens") or 0 for r in rs]
        lines.append(f"- {arm}: repeat reused {reused} of {toks}")
    lines.append("")
    return "\n".join(lines)


def summarize_eval(results: list) -> str:
    lines = ["# Quality gate (eval script)", ""]
    lines.append("| arm | ok | of | % | wall s | by category |")
    lines.append("|---|---|---|---|---|---|")
    for r in results:
        e = r.get("eval") or {}
        ok, of = e.get("ok"), e.get("of") or 0
        pct = (ok / of * 100) if of else 0
        lines.append(f"| {r['arm']} | {ok} | {of} | {pct:.1f} | {e.get('wall_s')} | "
                     + ", ".join(f"{k}={v}" for k, v in (e.get("by_cat") or {}).items()) + " |")
    lines.append("")
    base = next((r for r in results if r["arm"] == "control"), None)
    if base:
        b = (base.get("eval") or {}).get("ok") or 0
        for r in results:
            if r is base:
                continue
            o = (r.get("eval") or {}).get("ok") or 0
            lines.append(f"- {r['arm']}: {o} vs control {b} ({o - b:+d} items; gate is not >8 worse)")
    lines.append("")
    return "\n".join(lines)


# ------------------------------------------------------------------------------------ self-test


def self_test() -> int:
    """Check the metrics extraction and the paired summary without an engine."""
    failures = []

    def check(cond, msg):
        if not cond:
            failures.append(msg)

    reply = {"usage": {"completion_tokens": 12, "prompt_tokens": 400}}
    metrics = {
        "engine": {"version": "0.1.66", "expert_slots": 9156},
        "totals": {"requests": 5},
        "requests": [
            {
                "output_tokens": 12,
                "prompt_tokens": 400,
                "prompt_read": 390,
                "reused": 10,
                "prompt_ms": 1000.0,
                "decode_ms": 200.0,
                "decode_tok_s": 60.0,
                "drafts_offered": 10,
                "drafts_accepted": 8,
                "first_engine_token_s": 1.05,
                "hit_rate": 0.9,
                "finish": "stop",
            }
        ],
    }
    rec = extract_record(metrics, reply, {"requests": 4})
    check(rec["read_tok_s"] == 390.0, f"read_tok_s {rec['read_tok_s']}")
    check(rec["acceptance"] == 0.8, f"acceptance {rec['acceptance']}")
    check(rec["totals_requests_delta"] == 1, "totals delta")
    try:
        extract_record(metrics, {"usage": {"completion_tokens": 13}}, {"requests": 4})
        failures.append("mismatched reply should raise")
    except RuntimeError:
        pass

    meta = {"reps": 3, "cells": [("p1", 4252)], "date": "x", "engine_version": "0.1.66"}
    results = []
    for rep in range(3):
        results.append({"arm": "control", "rep": rep, "cell": "p1", "decode_tok_s": 100.0, "read_tok_s": 1000.0,
                        "prompt_tokens": 4252, "answer_sha": "a", "prompt_ms": 4000, "decode_ms": 2000,
                        "acceptance": 0.9})
        results.append({"arm": "verify_device_hits", "rep": rep, "cell": "p1", "decode_tok_s": 105.0,
                        "read_tok_s": 1001.0, "prompt_tokens": 4252, "answer_sha": "a", "prompt_ms": 4000,
                        "decode_ms": 2000, "acceptance": 0.9})
    text = summarize(results, ["control", "verify_device_hits", "l3_pf"], meta)
    check("ADOPT" in text, "a +5% exact arm should be an ADOPT")
    check("NO-WIN" not in text or "verify_device_hits" in text, "summary renders")

    # the no-magnitude-bar policy: +0.8% in every rep is adoptable, a 3/5 sign is not
    meta5 = {"reps": 5, "cells": [("p1", 4252)], "date": "x", "engine_version": "0.1.66"}
    results5 = []
    for rep in range(5):
        results5.append({"arm": "control", "rep": rep, "cell": "p1", "decode_tok_s": 100.0,
                         "read_tok_s": 1000.0, "prompt_tokens": 4252, "answer_sha": "a",
                         "prompt_ms": 4000, "decode_ms": 2000})
        results5.append({"arm": "verify_device_hits", "rep": rep, "cell": "p1", "decode_tok_s": 100.8,
                         "read_tok_s": 1000.0, "prompt_tokens": 4252, "answer_sha": "a",
                         "prompt_ms": 4000, "decode_ms": 2000})
        noisy = 101.0 if rep % 2 == 0 else 99.0
        results5.append({"arm": "l3_pf", "rep": rep, "cell": "p1", "decode_tok_s": noisy,
                         "read_tok_s": 1000.0, "prompt_tokens": 4252, "answer_sha": "a",
                         "prompt_ms": 4000, "decode_ms": 2000})
        results5.append({"arm": "renorm", "rep": rep, "cell": "p1", "decode_tok_s": 105.0,
                         "read_tok_s": 1000.0, "prompt_tokens": 4252, "answer_sha": "b",
                         "prompt_ms": 4000, "decode_ms": 2000})
    text5 = summarize(results5, ["control", "verify_device_hits", "l3_pf", "renorm"], meta5)

    def verdict_line(text, arm, cell):
        for line in text.splitlines():
            if line.startswith(f"- **{arm} / {cell}**"):
                return line
        return ""

    check("ADOPT" in verdict_line(text5, "verify_device_hits", "p1"),
          "a +0.8% all-reps arm must be adoptable without a magnitude bar")
    check("NO-WIN" in verdict_line(text5, "l3_pf", "p1"), "a 3/5 sign must not be adopted")
    check("ANSWER-CHANGING" in verdict_line(text5, "renorm", "p1"),
          "renorm must be sent to the quality gate")
    print("self-test:", "PASS" if not failures else "FAIL")
    for f in failures:
        print("  -", f)
    return 0 if not failures else 1


# ------------------------------------------------------------------------------------ main


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Counterbalanced A/B of Strata engine knobs (isolated port).")
    ap.add_argument("--config", required=False, help="the deployed engine config JSON (strata-<lane>.json)")
    ap.add_argument("--server-py", required=False, help="serve/server.py of the build under test")
    ap.add_argument("--engine-bin", default=None, help="bin/strata of the build under test (default: config exe)")
    ap.add_argument("--compare-bin", default=None, metavar="PATH",
                    help="also screen the PREVIOUS package's bin/strata (adds the prev_build arm)")
    ap.add_argument("--python", default=sys.executable, help="python3 that runs server.py (module's python)")
    ap.add_argument("--unit-env", default=None, metavar="UNIT",
                    help="read the deployed STRATA_* environment from this systemd unit (do this)")
    ap.add_argument("--base-env", action="append", default=[], metavar="KEY=VALUE",
                    help="environment the unit provides (e.g. LD_LIBRARY_PATH); repeatable")
    ap.add_argument("--workdir", default=None, help="evidence and state root (default /data/knob-screen-<stamp>)")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8099)
    ap.add_argument("--production-port", type=int, default=8081)
    ap.add_argument("--allow-production", action="store_true",
                    help="run even if the production engine looks alive on --production-port")
    ap.add_argument("--stop-unit", default=None, metavar="UNIT",
                    help="systemctl stop this unit for the screen and start it again on exit")
    ap.add_argument("--reps", type=int, default=5)
    ap.add_argument("--arms", default=None, help="comma list (default: throughput arms except renorm)")
    ap.add_argument("--cells", default="p1,p2,llive", help="comma list of p1,p2,llive")
    ap.add_argument("--max-tokens", type=int, default=128)
    ap.add_argument("--chars-per-token", type=float, default=4.3)
    ap.add_argument("--mode", choices=["throughput", "persist", "park", "eval"], default="throughput")
    ap.add_argument("--persist-fill", type=int, default=6, help="conversations to fill before the restart")
    ap.add_argument("--park-tokens", type=int, default=48000, help="park test: A's prompt tokens")
    ap.add_argument("--park-foreign", type=int, default=6000, help="park test: B's prompt tokens")
    ap.add_argument("--eval-script", default="/tmp/evalrun-ud.py", help="eval runner (temperature 0)")
    ap.add_argument("--eval-items", default="/data/eval320.json", help="eval item set")
    ap.add_argument("--eval-max-tokens", type=int, default=96)
    ap.add_argument("--api-key", default="")
    ap.add_argument("--start-timeout", type=float, default=300)
    ap.add_argument("--stop-timeout", type=float, default=30)
    ap.add_argument("--request-timeout", type=float, default=1800)
    ap.add_argument("--settle", type=float, default=3.0)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args(argv)

    if args.self_test:
        return self_test()

    missing = [n for n in ("config", "server_py") if not getattr(args, n)]
    if missing:
        ap.error("missing required " + ", ".join("--" + m.replace("_", "-") for m in missing))
    if args.compare_bin:
        ARMS["prev_build"]["engine_bin"] = args.compare_bin
    cfg = json.loads(Path(args.config).read_text())
    args.unit_env_map = unit_env(args.unit_env) if args.unit_env else {}
    env_keys = (
        set(os.environ)
        | set(args.unit_env_map)
        | set(cfg.get("env") or {})
        | {item.partition("=")[0] for item in (args.base_env or [])}
    )
    if "STRATA_SM75_PERF" not in env_keys:
        print("WARNING: STRATA_SM75_PERF is in neither the config's env nor the unit environment; "
              "this screen would not be running the deployed configuration", file=sys.stderr, flush=True)
    if not args.engine_bin:
        args.engine_bin = cfg.get("exe")
    if not args.engine_bin:
        ap.error("--engine-bin is required (the config has no exe)")

    if args.arms:
        arms = [a.strip() for a in args.arms.split(",") if a.strip()]
    elif args.mode == "persist":
        arms = ["control", "persist"]
    elif args.mode == "park":
        arms = ["control", "park_ram"]
    elif args.mode == "eval":
        arms = [a.strip() for a in (args.arms or "control").split(",") if a.strip()]
    else:
        arms = [a for a in ARMS if a not in ("renorm", "persist", "prev_build")]
        if args.compare_bin:
            arms.append("prev_build")
    if "prev_build" in arms and not args.compare_bin:
        ap.error("the prev_build arm needs --compare-bin PATH (the previous package's bin/strata)")
    unknown = [a for a in arms if a not in ARMS]
    if unknown:
        ap.error(f"unknown arms: {', '.join(unknown)}; known: {', '.join(ARMS)}")

    cells = [(c.strip(), dict(CELLS)[c.strip()]) for c in args.cells.split(",") if c.strip()]
    if any(c not in dict(CELLS) for c, _ in cells):
        ap.error(f"unknown cells: {[c for c, _ in cells if c not in dict(CELLS)]}")

    workdir = Path(args.workdir or f"/data/knob-screen-{datetime.now():%Y%m%d-%H%M}")
    if args.dry_run:
        print(f"mode: {args.mode}")
        print(f"workdir: {workdir}")
        print(f"port: {args.host}:{args.port}")
        print(f"engine: {args.engine_bin}")
        print(f"server: {args.server_py}")
        print(f"config: {args.config}")
        print(f"unit env: {len(getattr(args, 'unit_env_map', {}) or {})} vars from {args.unit_env or '(none)'}")
        print(f"config env: {len(cfg.get('env') or {})} engine vars (including the deployed knobs)")
        if args.mode == "throughput":
            for rep, order in plan_runs(arms, args.reps):
                print(f"rep {rep}: " + " -> ".join(order))
            runs = args.reps * len(arms)
            print(f"requests: {runs * len(cells)} (+1 warm-up per engine)")
            print(f"runs: {runs}; estimate ~{runs * 1.5:.0f} min wall (engine load is the bulk; split --arms to shorten the window)")
        elif args.mode == "persist":
            print(f"persist: {args.reps} reps x {len(arms)} arms x ({args.persist_fill} fill + 1 repeat + restart)")
        elif args.mode == "park":
            print(f"park: {args.reps} reps x {len(arms)} arms x (A {args.park_tokens} tok -> B {args.park_foreign} tok -> A repeat)")
        else:
            print(f"eval: {len(arms)} arms x {args.eval_items} via {args.eval_script}")
        return 0

    if not Path(args.server_py).is_file():
        ap.error(f"--server-py is not a file: {args.server_py}")
    if not Path(args.engine_bin).is_file():
        ap.error(f"--engine-bin is not a file: {args.engine_bin}")

    if port_open(args.host, args.port):
        raise SystemExit(f"port {args.host}:{args.port} is already in use; refusing to touch it")
    if port_open(args.host, args.production_port) and not args.allow_production:
        raise SystemExit(
            f"the production engine answers on {args.host}:{args.production_port}; a screen would contend for the GPU.\n"
            "Stop it first (--stop-unit restores it) and pass --allow-production to acknowledge."
        )

    shutdown = {"unit": args.stop_unit}

    def restore_unit():
        if shutdown["unit"]:
            unit = shutdown["unit"]
            shutdown["unit"] = None
            print(f"restoring {unit}", flush=True)
            subprocess.call(["systemctl", "start", unit])

    atexit.register(restore_unit)

    def on_signal(signum, _frame):
        raise SystemExit(128 + signum)

    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, on_signal)

    if args.stop_unit:
        print(f"stopping {args.stop_unit} (started again on exit)", flush=True)
        subprocess.check_call(["systemctl", "stop", args.stop_unit])
        wait_port_free(args.host, args.production_port, 60)

    workdir.mkdir(parents=True, exist_ok=True)
    (workdir / "logs").mkdir(exist_ok=True)
    (workdir / "config").mkdir(exist_ok=True)
    manifest = {
        "date": now_iso(),
        "argv": sys.argv,
        "script_sha256": sha256_file(Path(__file__).resolve()),
        "config": str(Path(args.config).resolve()),
        "config_sha256": sha256_file(Path(args.config)),
        "engine_bin": str(Path(args.engine_bin).resolve()),
        "server_py": str(Path(args.server_py).resolve()),
        "arms": arms,
        "cells": cells,
        "reps": args.reps,
        "mode": args.mode,
        "host": args.host,
        "port": args.port,
        "base_env": args.base_env,
        "unit_env": {"unit": args.unit_env, "keys": sorted(args.unit_env_map)},
        "config_env_keys": sorted(cfg.get("env") or {}),
        "compare_bin": args.compare_bin,
        "arm_env": {a: ARMS[a]["env"] for a in arms},
    }
    (workdir / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"evidence: {workdir}", flush=True)

    results = []
    failures = []
    started = time.time()

    def flush():
        (workdir / "results.json").write_text(json.dumps(results, indent=2) + "\n")
        if failures:
            (workdir / "failures.json").write_text(json.dumps(failures, indent=2) + "\n")

    if args.mode == "throughput":
        run_throughput(args, cfg, workdir, arms, args.reps, cells, results, failures, flush)
    elif args.mode == "persist":
        run_persist(args, cfg, workdir, args.reps, cells, results, failures, flush)
    elif args.mode == "park":
        run_park(args, cfg, workdir, arms, args.reps, cells, results, failures, flush)
    else:
        run_eval(args, cfg, workdir, arms, args.reps, cells, results, failures, flush)

    flush()
    engine_version = next((r.get("engine_version") for r in results if r.get("engine_version")), "unknown")
    start_line = next((r.get("engine_start_line") for r in results if r.get("engine_start_line")), "")
    expected = args.reps * len(arms) * len(cells) if args.mode == "throughput" else None
    meta = {"date": now_iso(), "engine_version": engine_version, "engine_start_line": start_line,
            "reps": args.reps, "cells": cells, "expected": expected}
    if args.mode == "throughput":
        summary = summarize(results, arms, meta)
    elif args.mode == "persist":
        summary = summarize_persist(results)
    elif args.mode == "park":
        summary = summarize_park(results)
    else:
        summary = summarize_eval(results)
    (workdir / "summary.md").write_text(summary + "\n")
    print("\n" + summary)
    print(f"\nwrote {workdir / 'results.json'} and {workdir / 'summary.md'} in {time.time() - started:.0f}s")
    return 0


def summarize_persist(results: list) -> str:
    lines = ["# Strata spill-persist restart test", ""]
    lines.append("| arm | rep | phase | reused | prompt tokens | answer sha |")
    lines.append("|---|---|---|---|---|---|")
    for r in results:
        lines.append(
            f"| {r['arm']} | {r['rep']} | {r.get('phase','')} | {r.get('reused')} | "
            f"{r.get('prompt_tokens')} | {r.get('answer_sha')} |"
        )
    repeats = [r for r in results if r.get("phase") == "repeat"]
    lines.append("")
    by = {}
    for r in repeats:
        by.setdefault(r["arm"], []).append(r.get("reused") or 0)
    lines.append("## Verdict")
    lines.append("")
    for arm, reused in by.items():
        lines.append(f"- {arm}: reused after restart = {reused} (control should be 0 or near it)")
    persist = by.get("persist") or []
    if persist and all(v > 0 for v in persist):
        lines.append("")
        lines.append("The spill tier survived the restart: adopt `--conversation-spill-persist` with a")
        lines.append("persistent `--conversation-spill-dir` and a boot sweep that keeps it (the module")
        lines.append("currently deletes only `*.park`).  Re-run with the deployed config before believing")
        lines.append("the bytes: check the engine log for the tier's own lines.")
    else:
        lines.append("")
        lines.append("No persistence shown.  Check the log for the spill tier's write/evict lines before")
        lines.append("concluding anything: with the RAM cache large enough, nothing spills and the test")
        lines.append("is inconclusive (raise --persist-fill).")
    lines.append("")
    return "\n".join(lines)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except Exception as exc:  # a screen must fail loudly and leave the unit restored (atexit)
        print(f"knob_screen: ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
