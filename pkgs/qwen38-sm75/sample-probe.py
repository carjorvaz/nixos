#!/usr/bin/env python3
"""Sampled-traffic probe: acceptance, per-position acceptance, throughput.

Sends N independent completions with the *default* sampling (temperature > 0,
top_k/top_p) and reports engine-side counters. Acceptance length is
1 + accepted_draft_tokens / draft_steps (one draft step per engine step), which
is also (generation_tokens / draft_steps).

Usage: qwen38-sm75-sample-probe --n 40 --max-tokens 32
       qwen38-sm75-sample-probe --n 1 --max-tokens 1024   # one long decode
"""
import argparse
import collections
import json
import re
import time
import urllib.request


def http(base, path, payload=None, timeout=3600):
    data = None if payload is None else json.dumps(payload).encode()
    request = urllib.request.Request(
        base + path, data=data, headers={"Content-Type": "application/json"}
    )
    return urllib.request.urlopen(request, timeout=timeout)


def scrape_metrics(base):
    values = {}
    with http(base, "/metrics") as response:
        for line in response.read().decode().splitlines():
            if line.startswith("#") or not line:
                continue
            match = re.match(r"([a-zA-Z0-9_:]+)(\{[^}]*\})?\s+([0-9.eE+-]+)$", line)
            if not match:
                continue
            name, labels, value = match.groups()
            key = name + (labels or "")
            try:
                values[key] = values.get(key, 0.0) + float(value)
            except ValueError:
                continue
    return values


def counter(values, name):
    return sum(v for k, v in values.items() if k.startswith(name))


def pos_counter(values, pos):
    key = f'position="{pos}"'
    return sum(
        v
        for k, v in values.items()
        if k.startswith("vllm:spec_decode_num_accepted_tokens_per_pos_total") and key in k
    )


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base-url", default="http://127.0.0.1:8080")
    ap.add_argument("--model", default="qwen3.8-27b")
    ap.add_argument("--n", type=int, default=60)
    ap.add_argument("--max-tokens", type=int, default=32)
    ap.add_argument("--temperature", type=float, default=1.0)
    ap.add_argument("--top-k", type=int, default=20)
    ap.add_argument("--top-p", type=float, default=0.95)
    ap.add_argument(
        "--prompt",
        default="Write one short sentence about the sea.",
    )
    ap.add_argument(
        "--text-file",
        default=None,
        help="use this text file as the prompt (~4 chars per token) instead",
    )
    ap.add_argument(
        "--prompt-tokens",
        type=int,
        default=2000,
        help="with --text-file, how many tokens of it to use",
    )
    ap.add_argument("--json-out", default=None)
    args = ap.parse_args()

    prompt = args.prompt
    if args.text_file:
        with open(args.text_file) as handle:
            body = handle.read()
        want = max(1, args.prompt_tokens) * 4
        while len(body) < want:
            body = body + "\n" + body
        prompt = body[:want]

    before = scrape_metrics(args.base_url)
    start = time.time()
    firsts: list[float] = []
    samples = []
    for _ in range(args.n):
        request_start = time.time()
        payload = {
            "model": args.model,
            "messages": [{"role": "user", "content": prompt}],
            "max_tokens": args.max_tokens,
            "temperature": args.temperature,
            "top_k": args.top_k,
            "top_p": args.top_p,
            "stream": True,
        }
        text = ""
        first_at = None
        with http(args.base_url, "/v1/chat/completions", payload, timeout=600) as r:
            for line in r:
                line = line.decode().strip()
                if not line.startswith("data: "):
                    continue
                blob = line[6:]
                if blob == "[DONE]":
                    break
                delta = json.loads(blob)
                for choice in delta.get("choices", []):
                    delta_obj = choice.get("delta") or {}
                    piece = (
                        delta_obj.get("content")
                        or delta_obj.get("reasoning_content")
                        or ""
                    )
                    if piece and first_at is None:
                        first_at = time.time()
                    text += piece
        samples.append(text)
        if first_at is not None:
            firsts.append(first_at - request_start)
    elapsed = time.time() - start

    after = scrape_metrics(args.base_url)
    steps = counter(after, "vllm:spec_decode_num_drafts_total") - counter(
        before, "vllm:spec_decode_num_drafts_total"
    )
    accepted = counter(after, "vllm:spec_decode_num_accepted_tokens_total") - counter(
        before, "vllm:spec_decode_num_accepted_tokens_total"
    )
    gen = counter(after, "vllm:generation_tokens_total") - counter(
        before, "vllm:generation_tokens_total"
    )
    acceptance = 1.0 + accepted / steps if steps else float("nan")
    per_pos = {}
    for pos in range(8):
        delta_pos = pos_counter(after, pos) - pos_counter(before, pos)
        if pos_counter(after, pos) or pos_counter(before, pos):
            per_pos[pos] = round(delta_pos / steps, 3) if steps else 0.0

    words = collections.Counter()
    for text in samples:
        found = re.findall(r"[A-Za-z']+", text)
        if found:
            words[found[0].lower()] += 1
    result = {
        "requests": args.n,
        "temperature": args.temperature,
        "top_k": args.top_k,
        "top_p": args.top_p,
        "steps": steps,
        "accepted_drafts": accepted,
        "acceptance_length": round(acceptance, 3),
        "generation_tokens": gen,
        "tok_per_step": round(gen / steps, 3) if steps else None,
        "elapsed_s": round(elapsed, 2),
        # Engine-side rates: they include the prefill, so compare arms with the
        # same prompt, or use steps_per_s with acceptance_length.
        "generation_tok_s": round(gen / elapsed, 2),
        "steps_per_s": round(steps / elapsed, 2) if elapsed else None,
        "step_ms": round(1000 * elapsed / steps, 2) if steps else None,
        # Client-side first-token latency, informational (it overlaps the decode
        # window when the server streams reasoning content).
        "ttft_s": round(sum(firsts) / len(firsts), 3) if firsts else None,
        "per_position_acceptance": per_pos,
        "top_first_words": words.most_common(6),
        "distinct_first_words": len(words),
    }
    print(json.dumps(result))
    if args.json_out:
        with open(args.json_out, "w") as handle:
            json.dump(result, handle)


if __name__ == "__main__":
    main()
