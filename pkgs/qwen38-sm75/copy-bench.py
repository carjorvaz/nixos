#!/usr/bin/env python3
"""Verbatim-reproduction bench: how well does speculation draft from context?

Builds a long filler prompt with a unique passage, asks the model to reproduce
the passage exactly, and reports TTFT, decode rate, acceptance and whether the
answer matches. Run against MTP and ngram speculation to see which draft source
pays on copy/edit workloads.

Pass --temperature 1.0 (with the model's top_k/top_p) to measure the sampled
case, which is what a client that sends no sampling parameters gets: the copy
then drifts off the verbatim text at long context and the history lookup does
not fire, because its proposals are point masses.

Usage: qwen38-sm75-copy-bench --words 32000 --output-tokens 512 [--temperature 1.0]
"""

import argparse
import json
import random
import time
import urllib.request

PASSAGE = (
    "The maintenance hatch code is KILO-NINER-FOUR-SIERRA. Before opening the west "
    "conduit, vent the secondary loop for ninety seconds, confirm the pressure gauge "
    "reads below two point four bar, and log the sequence in the red binder."
)


def post(base, path, payload, timeout=3600):
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


def stream(base, payload):
    first = last = None
    completion = None
    text = ""
    with post(base, "/v1/chat/completions", payload) as response:
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
            delta_content = (choices[0].get("delta") or {}).get("content") if choices else None
            if delta_content:
                text += delta_content
                now = time.monotonic()
                first = first or now
                last = now
    return completion, first, last, text


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", default="http://127.0.0.1:8081")
    parser.add_argument("--model", default="qwen3.8-27b")
    parser.add_argument("--words", type=int, default=32000)
    parser.add_argument("--output-tokens", type=int, default=96)
    parser.add_argument("--runs", type=int, default=2)
    parser.add_argument("--seed", type=int, default=20260917)
    parser.add_argument("--temperature", type=float, default=0)
    parser.add_argument("--top-k", type=int, default=20)
    parser.add_argument("--top-p", type=float, default=0.95)
    args = parser.parse_args()
    base = args.base_url.rstrip("/")
    rng = random.Random(args.seed)
    filler = ["note"] * args.words

    for run in range(args.runs):
        nonce = f"attempt-{rng.getrandbits(48):012x}"
        words = list(filler)
        words.insert(len(words) // 2, PASSAGE)
        prompt = nonce + " " + " ".join(words) + (
            "\n\nReproduce the maintenance instructions above word for word, exactly as "
            "written. Output only the passage, nothing else."
        )
        before = scrape(base)
        started = time.monotonic()
        completion, first, last, text = stream(base, {
            "model": args.model,
            "messages": [{"role": "user", "content": prompt}],
            "max_tokens": args.output_tokens,
            "temperature": args.temperature,
            "top_k": args.top_k,
            "top_p": args.top_p,
            "ignore_eos": True,
            "stream": True,
            "stream_options": {"include_usage": True},
            "chat_template_kwargs": {"enable_thinking": False},
        })
        after = scrape(base)
        # Recover the text from the second request is not kept; use a short
        # non-streaming call only for the exactness check when needed.
        drafts = delta(before, after, "vllm:spec_decode_num_drafts_total")
        accepted = delta(before, after, "vllm:spec_decode_num_accepted_tokens_total")
        acceptance = None if not drafts else round(1 + accepted / drafts, 3)
        decode = None
        if first and last and last > first and completion:
            decode = round((completion - 1) / (last - first), 2)
        print(json.dumps({
            "run": run,
            "ttft_s": round((first or started) - started, 2),
            "completion_tokens": completion,
            "decode_tok_s": decode,
            "acceptance": acceptance,
            "prompt_words": len(words),
            "copy_prefix": PASSAGE[:60].lower() in text.lower(),
            "copy_exact": PASSAGE.lower() in text.lower(),
        }, sort_keys=True), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
