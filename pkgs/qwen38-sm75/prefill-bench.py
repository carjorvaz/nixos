#!/usr/bin/env python3
"""Microbenchmark the Turing int4 prefill path: paged-KV gather vs attention.

Run under the runtime manifest's environment (see with_manifest_env in the
operator notes); it allocates the 1 GiB prefill workspace, so the serving
engine must be stopped on a 22 GiB card.

Mirrors the serving shapes: q = one prefill chunk (up to max-num-batched-tokens),
kv = the whole prompt for a cached-continuation tail (or the growing prefix for a
cold prefill). Splits the gather (dequantize paged int4 into the dense fp16
workspace) from the Cutlass attention so the tail's cost is attributable without
profiling a live server.

Usage: prefill_bench.py [--lengths 16384,32768,65536,131072] [--chunks 512,2048]
"""
import argparse
import math
import sys
import time

import torch

sys.path.insert(0, "/data/ab")
from vllm.v1.attention.ops.int4_per_token_head import _get_rht_signs  # noqa: E402
from vllm.v1.attention.ops.turing_prefill_attn import (  # noqa: E402
    _gather_kv,
    acquire_turing_prefill,
)

DIM = 256
HEADS = 24
KV_HEADS = 4
BLOCK = 16
DEVICE = "cuda"
SCALE = DIM ** -0.5


def build(length, block_size=BLOCK):
    blocks = math.ceil(length / block_size)
    data_dim = DIM // 2
    shape = (blocks, block_size, KV_HEADS, 2, data_dim + 4)
    storage = torch.randint(0, 256, shape, device=DEVICE, dtype=torch.uint8)
    ks = storage[..., 0, data_dim:].view(torch.float32).squeeze(-1)
    vs = storage[..., 1, data_dim:].view(torch.float32).squeeze(-1)
    # Plausible per-token-head scales; the harness uses the same range.
    ks.copy_(torch.rand_like(ks) * 0.02 + 0.001)
    vs.copy_(torch.rand_like(vs) * 0.02 + 0.001)
    key, value = storage[..., 0, :data_dim], storage[..., 1, :data_dim]
    table = torch.randperm(blocks, device=DEVICE, dtype=torch.int32)[None]
    return key, value, table, ks, vs


def timed(fn, warmup=2, iters=5):
    for _ in range(warmup):
        fn()
    torch.cuda.synchronize()
    start = time.perf_counter()
    for _ in range(iters):
        fn()
    torch.cuda.synchronize()
    return (time.perf_counter() - start) / iters


def gather_launch(workspace, key, value, ks, vs, table, length, rows, warps, stages):
    _gather_kv[(triton_cdiv(length, rows), KV_HEADS)](
        key, value, ks, vs, table,
        workspace.key, workspace.value, length,
        *key.stride(), *value.stride(),
        *ks.stride(), *vs.stride(),
        capacity=workspace.capacity, D=DIM, BLOCK=key.shape[1],
        QUANT=True, PACKED=True, ROWS=rows, num_warps=warps, num_stages=stages,
    )


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--lengths", default="16384,32768,65536,131072")
    ap.add_argument("--chunks", default="512,2048")
    ap.add_argument("--capacity", type=int, default=262144)
    ap.add_argument("--sweep-gather", action="store_true",
                    help="sweep ROWS/warps/stages of the gather kernel at one shape")
    args = ap.parse_args()

    lengths = [int(v) for v in args.lengths.split(",")]
    chunks = [int(v) for v in args.chunks.split(",")]
    workspace = acquire_turing_prefill(args.capacity, KV_HEADS, DIM, DEVICE)
    signs = _get_rht_signs(DIM, 0, torch.device(DEVICE))

    if args.sweep_gather:
        length, chunk = lengths[0], chunks[-1]
        key, value, table, ks, vs = build(length)
        q = torch.randn(chunk, HEADS, DIM, device=DEVICE, dtype=torch.float16)
        out = torch.empty_like(q)
        print(f"gather sweep at kv={length} q={chunk}")
        for rows in (8, 16, 32, 64):
            for warps in (4, 8):
                for stages in (1, 2):
                    ms = timed(lambda r=rows, w=warps, st=stages: gather_launch(
                        workspace, key, value, ks, vs, table, length, r, w, st)) * 1e3
                    print(f"  ROWS={rows:<3} warps={warps} stages={stages} -> {ms:.2f} ms")
        del key, value, table, ks, vs
        torch.cuda.empty_cache()
        return

    print(f"{'kv':>8} {'q':>6} {'run_ms':>8} {'gather_ms':>10} {'attn_ms':>8} "
          f"{'q_tok/s':>9} {'kv_GB/s':>8}")
    for length in lengths:
        key, value, table, ks, vs = build(length)
        for chunk in chunks:
            q = torch.randn(chunk, HEADS, DIM, device=DEVICE, dtype=torch.float16)
            out = torch.empty_like(q)

            def run():
                workspace.run(q, key, value, out, table, length, SCALE, ks, vs)

            gather_ms = timed(lambda: gather_launch(
                workspace, key, value, ks, vs, table, length, 16, 4, 1)) * 1e3
            run_ms = timed(run) * 1e3
            attn_ms = run_ms - gather_ms
            kv_bytes = length * KV_HEADS * 2 * (DIM // 2)  # packed int4 payload
            print(f"{length:>8} {chunk:>6} {run_ms:>8.2f} {gather_ms:>10.2f} "
                  f"{attn_ms:>8.2f} {chunk / (run_ms / 1e3):>9.0f} "
                  f"{kv_bytes / (gather_ms / 1e3) / 1e9:>8.1f}")
        del key, value, table, ks, vs
        torch.cuda.empty_cache()


def triton_cdiv(a, b):
    return (a + b - 1) // b


if __name__ == "__main__":
    main()
