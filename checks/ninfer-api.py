#!/usr/bin/env python3
"""Opt-in live NInfer checks; never run by public-safe validation or CI."""

import argparse
import json
import time
import urllib.error
import urllib.request
import uuid


def prompt_near_token_count(make_prompt, count, target):
    """Correct the initial estimate using full-prompt tokenization before inference."""
    fixed = count(make_prompt(0))
    per_repeat = (count(make_prompt(100)) - fixed) / 100
    assert per_repeat > 0, "Filler must increase the token count"
    repeats = max(0, int((target - fixed) / per_repeat))
    for _ in range(8):
        prompt = make_prompt(repeats)
        measured = count(prompt)
        if abs(measured - target) <= 32:
            return prompt, measured
        correction = round((target - measured) / per_repeat)
        if correction == 0:
            correction = 1 if measured < target else -1
        repeats = max(0, repeats + correction)
    raise AssertionError(f"Cannot size fixture before inference: {measured=} {target=}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("url", help="Explicit server base URL, without /v1")
    parser.add_argument("--model", default="qwen3.8-27b")
    parser.add_argument("--long-context", action="store_true", help="Also test near-limit cold prefill")
    parser.add_argument("--recompute", action="store_true", help="With --long-context, require full recomputation after replacement")
    parser.add_argument("--context-size", type=int, help="Required with --long-context: capacity to qualify")
    parser.add_argument("--timeout", type=int, default=3600, help="Request timeout in seconds")
    args = parser.parse_args()
    if args.long_context and args.context_size is None:
        parser.error("--long-context requires an explicit --context-size")
    if args.recompute and not args.long_context:
        parser.error("--recompute requires --long-context")
    if (args.context_size is not None and args.context_size < 4096) or args.timeout < 1:
        parser.error("context-size must be at least 4096 and timeout must be positive")
    base = args.url.rstrip("/")

    def request(path, body=None, timeout=None, expected_status=200):
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(
            base + path, data=data, headers={"Content-Type": "application/json"}
        )
        try:
            response = urllib.request.urlopen(req, timeout=args.timeout if timeout is None else timeout)
        except urllib.error.HTTPError as exc:
            if exc.code != expected_status:
                raise RuntimeError(f"HTTP {exc.code}: {exc.read().decode()}") from exc
            response = exc
        if response.status != expected_status:
            status = response.status
            response.close()
            raise RuntimeError(f"Expected HTTP {expected_status}, got {status}")
        return response

    def post(path, body):
        with request(path, body) as response:
            return json.load(response)

    def chat(messages, **extra):
        start = time.monotonic()
        result = post(
            "/v1/chat/completions",
            dict(
                model=args.model,
                messages=messages,
                max_tokens=256,
                temperature=0,
                reasoning_effort="none",
            ) | extra,
        )
        assert result["choices"], result
        assert "error" not in result, result
        return result, time.monotonic() - start

    with request("/health", timeout=10) as response:
        assert response.status == 200
    with request("/v1/models", timeout=10) as response:
        assert args.model in [model["id"] for model in json.load(response)["data"]]
    print("PASS health and model alias", flush=True)

    arithmetic = [{"role": "user", "content": "What is 17 + 25? Answer with the number only."}]
    result, elapsed = chat(arithmetic)
    assert result["choices"][0]["message"]["content"].strip() == "42", result
    print(f"PASS non-thinking generation ({elapsed:.2f}s)", flush=True)

    result, elapsed = chat(arithmetic, reasoning_effort="low", max_tokens=512)
    message = result["choices"][0]["message"]
    assert "42" in (message.get("content") or ""), result
    assert message.get("reasoning_content"), result
    print(f"PASS separate reasoning/content ({elapsed:.2f}s)", flush=True)

    stream_body = dict(
        model=args.model, messages=arithmetic, max_tokens=64,
        temperature=0, reasoning_effort="none", stream=True,
        stream_options={"include_usage": True},
    )
    content, done, finished, usage = "", False, False, None
    with request("/v1/chat/completions", stream_body) as response:
        for raw in response:
            line = raw.decode().strip()
            if not line.startswith("data: "):
                continue
            payload = line[6:]
            if payload == "[DONE]":
                done = True
                break
            event = json.loads(payload)
            assert "error" not in event, event
            if event.get("usage"):
                usage = event["usage"]
            for choice in event.get("choices", []):
                content += choice.get("delta", {}).get("content") or ""
                finished |= choice.get("finish_reason") is not None
    assert done and finished and usage and content.strip() == "42", (done, finished, usage, content)
    print("PASS SSE content, finish, usage and DONE", flush=True)

    tools = [{
        "type": "function",
        "function": {
            "name": "add_integers",
            "description": "Add two integers and return their sum.",
            "parameters": {
                "type": "object",
                "properties": {"a": {"type": "integer"}, "b": {"type": "integer"}},
                "required": ["a", "b"],
                "additionalProperties": False,
            },
        },
    }]
    history = [{
        "role": "user",
        "content": "Call add_integers with a=17 and b=25. Use the tool before answering.",
    }]
    result, _ = chat(history, tools=tools, tool_choice="auto")
    message = result["choices"][0]["message"]
    assert result["choices"][0]["finish_reason"] == "tool_calls", result
    calls = message.get("tool_calls") or []
    assert len(calls) == 1 and calls[0]["function"]["name"] == "add_integers", result
    call = calls[0]
    values = json.loads(call["function"]["arguments"])
    assert values == {"a": 17, "b": 25}, values
    # Only this fixed local arithmetic fixture is executed, never arbitrary tools.
    history += [message, {
        "role": "tool", "tool_call_id": call["id"], "content": str(values["a"] + values["b"]),
    }]
    result, _ = chat(history, tools=tools, tool_choice="auto")
    assert "42" in (result["choices"][0]["message"].get("content") or ""), result
    print("PASS tool call, arguments and result roundtrip", flush=True)

    if args.long_context:
        salt = uuid.uuid4().hex
        markers = [f"alpha-{salt[:8]}", f"beta-{salt[8:16]}", f"gamma-{salt[16:24]}"]
        filler = "This is irrelevant padding for a context retrieval test. "

        def make_prompt(repeats):
            return (
                f"Unique test {salt}. Remember three exact codes. ALPHA is {markers[0]}.\n"
                + filler * (repeats // 2)
                + f"\nBETA is {markers[1]}.\n"
                + filler * (repeats - repeats // 2)
                + f"\nGAMMA is {markers[2]}.\n"
                + "Return the ALPHA, BETA and GAMMA codes exactly, and nothing else."
            )

        def count(prompt):
            # This pin's counting endpoint accepts only model + input.
            return post("/v1/responses/input_tokens", {"model": args.model, "input": prompt})["input_tokens"]

        # Reserve 5% (at least 1K tokens) for generation and continuation.
        target = args.context_size - max(1024, args.context_size // 20)
        prompt, measured = prompt_near_token_count(make_prompt, count, target)
        print(f"Prepared near-limit fixture ({measured} tokens, target {target})", flush=True)
        # This pin exposes cache counts on Responses, not Chat Completions.
        # Missing metadata must not be mistaken for a zero-token cache hit.
        def respond(text, **extra):
            start = time.monotonic()
            result = post("/v1/responses", dict(
                model=args.model, input=text, max_output_tokens=256,
                temperature=0, reasoning={"effort": "none"},
            ) | extra)
            assert result["status"] == "completed", result
            return result, time.monotonic() - start

        def response_text(result):
            return "".join(
                part["text"] for item in result["output"] if item["type"] == "message"
                for part in item["content"] if part["type"] == "output_text"
            )

        result, elapsed = respond(prompt)
        cold_tokens = result["usage"]["input_tokens"]
        assert target - 256 <= cold_tokens <= target + 256, {
            "target": target, "measured": measured, "markers": markers, "response": result,
        }
        assert cold_tokens + 512 < args.context_size, result["usage"]
        assert all(code in response_text(result) for code in markers), result
        assert result["usage"]["input_tokens_details"]["cached_tokens"] == 0
        cold_id = result["id"]
        print(f"PASS cold near-limit retrieval ({cold_tokens} tokens, {elapsed:.2f}s)", flush=True)

        result, elapsed = respond(
            "Repeat those three codes exactly.", previous_response_id=result["id"],
        )
        assert all(code in response_text(result) for code in markers), result
        cached = result["usage"]["input_tokens_details"]["cached_tokens"]
        assert cached >= cold_tokens * 0.9, result["usage"]
        cached_text = response_text(result)
        cached_input_tokens = result["usage"]["input_tokens"]
        assert cached_input_tokens >= cold_tokens, result["usage"]
        print(f"PASS cached continuation ({cached} cached tokens, {elapsed:.2f}s)", flush=True)

        result, elapsed = respond(
            f"Unrelated fresh test {uuid.uuid4().hex}. What is 6 times 7? Number only.",
        )
        assert response_text(result).strip() == "42", result
        assert result["usage"]["input_tokens_details"]["cached_tokens"] < 100
        print(f"PASS unrelated-prefix replacement ({elapsed:.2f}s)", flush=True)

        if args.recompute:
            # The same original conversation, not a new easier prompt. CPU
            # response history is retained, but the GPU prefix must be evicted.
            result, elapsed = respond(
                "Repeat those three codes exactly.", previous_response_id=cold_id,
            )
            assert result["usage"]["input_tokens_details"]["cached_tokens"] == 0, result["usage"]
            assert result["usage"]["input_tokens"] == cached_input_tokens, result["usage"]
            assert response_text(result) == cached_text, result
            print(f"PASS full recomputation and cached-text equality ({elapsed:.2f}s)", flush=True)

        oversized, _ = prompt_near_token_count(make_prompt, count, args.context_size + 1024)
        assert count(oversized) > args.context_size
        with request("/v1/responses", dict(
            model=args.model, input=oversized, max_output_tokens=16,
            temperature=0, reasoning={"effort": "none"},
        ), timeout=30, expected_status=400) as response:
            error = json.load(response)
        assert error["error"]["code"] == "context_length_exceeded", error
        result, _ = respond("What is 6 times 7? Number only.")
        assert response_text(result).strip() == "42", result
        print("PASS over-limit rejection and subsequent generation", flush=True)


if __name__ == "__main__":
    main()
