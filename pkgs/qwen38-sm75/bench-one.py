#!/usr/bin/env python3
"""Measure decode rate, speculative acceptance and prefix caching on a live server.

This talks to a *running* OpenAI-compatible vLLM endpoint; it never starts or
stops one. Use it for A/B runs:

    qwen38-sm75-bench --prompt-tokens 8000 --output-tokens 256
    qwen38-sm75-bench --base-url http://127.0.0.1:8080 --runs 3

Each run streams one greedy request and reports the engine-side counters
(drafts, accepted tokens and their per-position split, prefix-cache queries and
hits) as deltas over the request, plus the client-side decode rate. Acceptance
length is 1 + accepted/drafts; decode rate is (completion_tokens - 1) /
(time of last token - time of first token), so the first token and the prefill
are excluded. Numbers from different prompt/output lengths are not comparable.
"""

import argparse
import json
import re
import sys
import time
import urllib.request


def http(base, path, payload=None, timeout=3600):
    data = None if payload is None else json.dumps(payload).encode()
    request = urllib.request.Request(
        base + path,
        data=data,
        headers={"Content-Type": "application/json"},
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


def counter(values, name, **labels):
    total = 0.0
    for key, value in values.items():
        if not key.startswith(name):
            continue
        if all(f'{label}="{text}"' in key for label, text in labels.items()):
            total += value
    return total


def stream(base, model, prompt, max_tokens):
    payload = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "temperature": 0,
        "ignore_eos": True,
        "stream": True,
        "stream_options": {"include_usage": True},
        "chat_template_kwargs": {"enable_thinking": False},
    }
    first = last = None
    completion = None
    with http(base, "/v1/chat/completions", payload) as response:
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
            if not choices:
                continue
            delta = choices[0].get("delta") or {}
            if delta.get("content"):
                now = time.monotonic()
                first = first or now
                last = now
    return completion, first, last


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", default="http://127.0.0.1:8080")
    parser.add_argument("--model", default="qwen3.8-27b")
    parser.add_argument("--prompt-tokens", type=int, default=8000)
    parser.add_argument("--output-tokens", type=int, default=256)
    parser.add_argument("--runs", type=int, default=1)
    parser.add_argument("--word", default="benchmark")
    args = parser.parse_args()
    base = args.base_url.rstrip("/")

    # One word per token is close enough for a repeated filler prompt; the
    # server's own usage counts are what get reported.
    prompt = " ".join([args.word] * args.prompt_tokens)
    results = []
    for run in range(args.runs):
        before = scrape_metrics(base)
        started = time.monotonic()
        completion, first, last = stream(base, args.model, prompt, args.output_tokens)
        after = scrape_metrics(base)
        drafts = counter(after, "vllm:spec_decode_num_drafts_total") - counter(
            before, "vllm:spec_decode_num_drafts_total"
        )
        accepted = counter(
            after, "vllm:spec_decode_num_accepted_tokens_total"
        ) - counter(before, "vllm:spec_decode_num_accepted_tokens_total")
        per_pos = {
            position: counter(
                after,
                "vllm:spec_decode_num_accepted_tokens_per_pos_total",
                position=str(position),
            )
            - counter(
                before,
                "vllm:spec_decode_num_accepted_tokens_per_pos_total",
                position=str(position),
            )
            for position in range(4)
        }
        queries = counter(after, "vllm:prefix_cache_queries_total") - counter(
            before, "vllm:prefix_cache_queries_total"
        )
        hits = counter(after, "vllm:prefix_cache_hits_total") - counter(
            before, "vllm:prefix_cache_hits_total"
        )
        decode = None
        if first is not None and last is not None and last > first and completion:
            decode = (completion - 1) / (last - first)
        result = {
            "run": run,
            "prompt_tokens_requested": args.prompt_tokens,
            "completion_tokens": completion,
            "ttft_s": None if first is None else round(first - started, 6),
            "decode_tok_s": None if decode is None else round(decode, 2),
            "drafts": drafts,
            "accepted": accepted,
            "acceptance_length": None if not drafts else round(1 + accepted / drafts, 3),
            "accepted_per_position": per_pos,
            "prefix_queries": queries,
            "prefix_hits": hits,
        }
        results.append(result)
        print(json.dumps(result, sort_keys=True), flush=True)
    if len(results) > 1:
        decodes = [r["decode_tok_s"] for r in results if r["decode_tok_s"]]
        if decodes:
            print(
                json.dumps(
                    {
                        "summary": {
                            "runs": len(decodes),
                            "decode_tok_s_mean": round(sum(decodes) / len(decodes), 2),
                            "decode_tok_s_min": min(decodes),
                            "decode_tok_s_max": max(decodes),
                        }
                    },
                    sort_keys=True,
                )
            )
    return 0


if __name__ == "__main__":
    sys.exit(main())
