#!/usr/bin/env python3
"""Measure decode rate and speculative acceptance on a live llama-server.

This talks to a *running* llama.cpp/beellama OpenAI-compatible endpoint; it
never starts or stops one. It mirrors pkgs/qwen38-sm75/bench-one.py so A/B
numbers against vLLM are directly comparable:

    bench-llama.py --prompt-tokens 8000 --output-tokens 256
    bench-llama.py --base-url http://127.0.0.1:8081 --runs 3

Acceptance length is 1 + accepted/drafts, where drafts counts speculative
steps (not draft tokens), the same convention as vLLM's spec_decode metrics.
Decode rate excludes prefill and the first token. Numbers from different
prompt/output lengths are not comparable.
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


def counter(values, name):
    total = 0.0
    for key, value in values.items():
        if key == name or key.startswith(name + "{"):
            total += value
    return total


def stream(base, model, prompt, max_tokens, temperature):
    payload = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "temperature": temperature,
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
    parser.add_argument("--base-url", default="http://127.0.0.1:8081")
    parser.add_argument("--model", default="qwen38-llama")
    parser.add_argument("--prompt-tokens", type=int, default=8000)
    parser.add_argument("--output-tokens", type=int, default=256)
    parser.add_argument("--runs", type=int, default=1)
    parser.add_argument("--word", default="benchmark")
    parser.add_argument("--temperature", type=float, default=0.0)
    parser.add_argument("--text-file", default=None)
    parser.add_argument(
        "--nonce",
        action="store_true",
        help=(
            "prepend a unique token to defeat the server's prefix cache so the "
            "reported prefill rate is a cold one. Without it, a repeated prompt "
            "is served from cache and prefill_tok_s only covers the tail."
        ),
    )
    args = parser.parse_args()
    base = args.base_url.rstrip("/")

    if args.text_file:
        with open(args.text_file) as handle:
            body = handle.read()
        want = max(1, args.prompt_tokens) * 4
        while len(body) < want:
            body = body + "\n" + body
        prompt = body[:want]
    else:
        prompt = " ".join([args.word] * args.prompt_tokens)
    if args.nonce:
        prompt = f"nonce-{time.time_ns()}-{id(args)} " + prompt
    results = []
    for run in range(args.runs):
        before = scrape_metrics(base)
        started = time.monotonic()
        completion, first, last = stream(
            base, args.model, prompt, args.output_tokens, args.temperature
        )
        after = scrape_metrics(base)
        drafts = counter(after, "llamacpp:spec_decode_num_drafts_total") - counter(
            before, "llamacpp:spec_decode_num_drafts_total"
        )
        accepted = counter(
            after, "llamacpp:spec_decode_num_accepted_tokens_total"
        ) - counter(before, "llamacpp:spec_decode_num_accepted_tokens_total")
        draft_tokens = counter(
            after, "llamacpp:spec_decode_num_draft_tokens_total"
        ) - counter(before, "llamacpp:spec_decode_num_draft_tokens_total")
        prompt_total = counter(after, "llamacpp:prompt_tokens_total") - counter(
            before, "llamacpp:prompt_tokens_total"
        )
        prompt_cached = counter(
            after, "llamacpp:prompt_tokens_cached_total"
        ) - counter(before, "llamacpp:prompt_tokens_cached_total")
        prompt_seconds = counter(
            after, "llamacpp:prompt_seconds_total"
        ) - counter(before, "llamacpp:prompt_seconds_total")
        predicted = counter(after, "llamacpp:tokens_predicted_total") - counter(
            before, "llamacpp:tokens_predicted_total"
        )
        predicted_seconds = counter(
            after, "llamacpp:tokens_predicted_seconds_total"
        ) - counter(before, "llamacpp:tokens_predicted_seconds_total")
        decode = None
        if first is not None and last is not None and last > first and completion:
            decode = (completion - 1) / (last - first)
        result = {
            "run": run,
            "prompt_tokens_requested": args.prompt_tokens,
            "prompt_tokens_counted": prompt_total,
            "prompt_tokens_cached": prompt_cached,
            "completion_tokens": completion,
            "ttft_s": None if first is None else round(first - started, 6),
            "decode_tok_s": None if decode is None else round(decode, 2),
            "drafts": drafts,
            "accepted": accepted,
            "draft_tokens": draft_tokens,
            "acceptance_length": None
            if not drafts
            else round(1 + accepted / drafts, 3),
            "acceptance_per_draft_token": None
            if not draft_tokens
            else round(accepted / draft_tokens, 4),
            "prefill_tok_s": None
            if not prompt_seconds
            else round(prompt_total / prompt_seconds, 1),
            "server_decode_tok_s": None
            if not predicted_seconds
            else round(predicted / predicted_seconds, 2),
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
