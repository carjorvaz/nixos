#!/usr/bin/env python3
"""Sustained mixed-load soak for a running Qwen server.

Keeps three workers busy with short, medium and long prompts (cold and
prefix-cached), samples nvidia-smi, Xid counts and engine metrics, and writes
a summary. Read-only against the server; never restarts it.
"""

import argparse
import json
import random
import re
import subprocess
import sys
import threading
import time
import urllib.request

STOP = threading.Event()
LOCK = threading.Lock()
STATS = {"requests": 0, "errors": 0, "decode": [], "ttft": [], "accept": [], "cached": [], "by_size": {}}


def post(base, path, payload, timeout):
    request = urllib.request.Request(
        base + path, data=json.dumps(payload).encode(), headers={"Content-Type": "application/json"}
    )
    return urllib.request.urlopen(request, timeout=timeout)


def scrape(base):
    values = {}
    with urllib.request.urlopen(base + "/metrics", timeout=60) as response:
        for line in response.read().decode().splitlines():
            if line.startswith("#") or not line or " " not in line:
                continue
            name, _, rest = line.partition(" ")
            try:
                values[name] = values.get(name, 0.0) + float(rest.split()[0])
            except ValueError:
                pass
    return values


def delta(before, after, prefix):
    keys = [k for k in after if k.startswith(prefix)]
    return sum(after[k] for k in keys) - sum(before.get(k, 0.0) for k in keys)


def chat(base, model, content, max_tokens, timeout):
    payload = {
        "model": model,
        "messages": [{"role": "user", "content": content}],
        "max_tokens": max_tokens,
        "temperature": 0,
        "ignore_eos": True,
        "stream": True,
        "stream_options": {"include_usage": True},
        "chat_template_kwargs": {"enable_thinking": False},
    }
    started = time.monotonic()
    first = last = None
    completion = None
    with post(base, "/v1/chat/completions", payload, timeout) as response:
        for raw in response:
            line = raw.decode().strip()
            if not line.startswith("data: "):
                continue
            chunk = line[6:]
            if chunk == "[DONE]":
                break
            event = json.loads(chunk)
            if event.get("usage"):
                completion = event["usage"].get("completion_tokens")
            choices = event.get("choices") or []
            if choices and (choices[0].get("delta") or {}).get("content"):
                now = time.monotonic()
                first = first or now
                last = now
    decode = None
    if first and last and last > first and completion:
        decode = (completion - 1) / (last - first)
    return completion, (first - started if first else None), decode


def worker(base, model, sizes, deadline):
    rng = random.Random(threading.get_ident())
    pool = {size: " ".join(["soak"] * size) for size in sizes}
    while not STOP.is_set() and time.monotonic() < deadline:
        size = rng.choices(sizes, weights=[4, 3, 2, 1][: len(sizes)])[0]
        content = pool[size]
        cold = rng.random() < 0.65
        if cold:
            content = f"nonce-{rng.getrandbits(48):012x} " + content
        try:
            before = scrape(base)
            completion, ttft, decode = chat(base, model, content, 128, 1800)
            after = scrape(base)
            with LOCK:
                STATS["requests"] += 1
                if decode:
                    STATS["decode"].append(round(decode, 2))
                if ttft:
                    STATS["ttft"].append(round(ttft, 2))
                queries = delta(before, after, "vllm:prefix_cache_queries_total")
                hits = delta(before, after, "vllm:prefix_cache_hits_total")
                if queries:
                    STATS["cached"].append(round(hits / queries, 3))
                drafts = delta(before, after, "vllm:spec_decode_num_drafts_total")
                accepted = delta(before, after, "vllm:spec_decode_num_accepted_tokens_total")
                if drafts:
                    STATS["accept"].append(round(1 + accepted / drafts, 3))
                entry = STATS["by_size"].setdefault(str(size), {"requests": 0, "decode": []})
                entry["requests"] += 1
                if decode:
                    entry["decode"].append(round(decode, 2))
        except Exception as error:  # noqa: BLE001 - record and continue
            with LOCK:
                STATS["errors"] += 1
                STATS["by_size"].setdefault(str(size), {"requests": 0, "decode": []})
            print(f"error size={size}: {type(error).__name__}: {error}", flush=True)


def dmesg_xid():
    """Number of Xid lines in the kernel ring, plus the first line text."""
    try:
        out = subprocess.run(["dmesg"], capture_output=True, text=True, timeout=20).stdout
    except Exception:
        return None, None
    lines = [line for line in out.splitlines() if "Xid" in line]
    return len(lines), (lines[0] if lines else None)


def monitor(out_dir, base, deadline):
    csv = open(out_dir + "/soak-gpu.csv", "w")
    csv.write("epoch,power_w,temp_c,sm_mhz,util_pct,mem_mib\n")
    baseline = dmesg_xid()[0] or 0
    next_xid = time.monotonic() + 30
    while not STOP.is_set() and time.monotonic() < deadline:
        try:
            with urllib.request.urlopen(base + "/metrics", timeout=30) as response:
                body = response.read()
        except Exception:
            body = b""
        try:
            out = subprocess.run(
                ["nvidia-smi", "--query-gpu=power.draw,temperature.gpu,clocks.sm,utilization.gpu,memory.used", "--format=csv,noheader,nounits"],
                capture_output=True, text=True, timeout=30,
            ).stdout.strip()
            csv.write(f"{time.time():.0f},{out}\n")
            csv.flush()
        except Exception:
            pass
        if time.monotonic() >= next_xid:
            next_xid = time.monotonic() + 30
            count, first = dmesg_xid()
            if count is not None:
                with LOCK:
                    STATS["xid"] = count
                if count > baseline:
                    print(f"XID_DETECTED count={count} first={first}", flush=True)
                    STOP.set()
                    break
        time.sleep(10)
    csv.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", default="http://127.0.0.1:8080")
    parser.add_argument("--model", default="qwen3.8-27b")
    parser.add_argument("--minutes", type=float, default=75)
    parser.add_argument("--workers", type=int, default=3)
    parser.add_argument("--sizes", default="256,1024,4096,16384")
    parser.add_argument("--out-dir", default="/data/ab")
    args = parser.parse_args()
    sizes = [int(value) for value in args.sizes.split(",")]
    deadline = time.monotonic() + args.minutes * 60
    monitor_thread = threading.Thread(target=monitor, args=(args.out_dir, args.base_url.rstrip("/"), deadline), daemon=True)
    monitor_thread.start()
    workers = [
        threading.Thread(target=worker, args=(args.base_url.rstrip("/"), args.model, sizes, deadline), daemon=True)
        for _ in range(args.workers)
    ]
    for thread in workers:
        thread.start()
    try:
        while any(thread.is_alive() for thread in workers):
            time.sleep(30)
            with LOCK:
                summary = {
                    "requests": STATS["requests"],
                    "errors": STATS["errors"],
                    "decode_mean": round(sum(STATS["decode"]) / len(STATS["decode"]), 2) if STATS["decode"] else None,
                    "accept_mean": round(sum(STATS["accept"]) / len(STATS["accept"]), 3) if STATS["accept"] else None,
                    "cache_hit_mean": round(sum(STATS["cached"]) / len(STATS["cached"]), 3) if STATS["cached"] else None,
                    "xid": STATS.get("xid", 0),
                }
            print(json.dumps(summary, sort_keys=True), flush=True)
    finally:
        STOP.set()
    with LOCK:
        result = dict(STATS)
        result["decode_mean"] = round(sum(STATS["decode"]) / len(STATS["decode"]), 2) if STATS["decode"] else None
        result["ttft_mean"] = round(sum(STATS["ttft"]) / len(STATS["ttft"]), 2) if STATS["ttft"] else None
        result["accept_mean"] = round(sum(STATS["accept"]) / len(STATS["accept"]), 3) if STATS["accept"] else None
        result["cache_hit_mean"] = round(sum(STATS["cached"]) / len(STATS["cached"]), 3) if STATS["cached"] else None
    for entry in result["by_size"].values():
        entry["decode_mean"] = round(sum(entry["decode"]) / len(entry["decode"]), 2) if entry["decode"] else None
        entry["decode"] = len(entry["decode"])
    print("SOAK_RESULT " + json.dumps({k: v for k, v in result.items() if k != "decode"}), flush=True)
    return 0 if result["errors"] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
