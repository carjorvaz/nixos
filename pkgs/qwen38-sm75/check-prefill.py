#!/usr/bin/env python3
"""Check paged FP16/INT8/INT4 prefill against explicit FP32 references."""

import importlib.util
import math
from pathlib import Path

import torch
from vllm.v1.attention.ops.turing_prefill_attn import TuringPrefillAttention


reference_spec = importlib.util.spec_from_file_location(
    "attention_reference", Path(__file__).with_name("check-attention.py")
)
reference = importlib.util.module_from_spec(reference_spec)
reference_spec.loader.exec_module(reference)

torch.manual_seed(517)
torch.backends.cuda.matmul.allow_tf32 = False
DEVICE = torch.device("cuda", 0)
HEADS, KV_HEADS, DIM = 24, 4, 256
workspace = TuringPrefillAttention(262144, KV_HEADS, DIM, DEVICE)


def check(length, queries, block_size, quantized, packed=False):
    blocks = math.ceil(length / block_size)
    # Interleaved K/V, padded head rows and strided scales match the server's
    # non-contiguous views. Permuted pages catch accidental contiguous reads.
    data_dim = DIM // 2 if packed else DIM
    shape = (blocks, block_size, KV_HEADS, 2, data_dim + 4)
    if packed:
        storage = torch.randint(0, 256, shape, device=DEVICE, dtype=torch.uint8)
        ks = storage[..., 0, data_dim:].view(torch.float32).squeeze(-1)
        vs = storage[..., 1, data_dim:].view(torch.float32).squeeze(-1)
        reference.fill_int4_scales(ks)
        reference.fill_int4_scales(vs)
    elif quantized:
        storage = torch.randint(-127, 128, shape, device=DEVICE, dtype=torch.int8)
        scales = (
            torch.rand((blocks, block_size, KV_HEADS, 2), device=DEVICE) * 0.02 + 0.001
        )
        ks, vs = scales[..., 0], scales[..., 1]
    else:
        storage = torch.randn(shape, device=DEVICE, dtype=torch.float16)
        ks = vs = None
    key, value = storage[..., 0, :data_dim], storage[..., 1, :data_dim]
    table = torch.randperm(blocks, device=DEVICE, dtype=torch.int32)[None]
    if packed and length % block_size:
        last_page = table[0, -1].long()
        storage[last_page, length % block_size :].fill_(255)
        ks[last_page, length % block_size :].fill_(torch.nan)
        vs[last_page, length % block_size :].fill_(torch.nan)
    q = torch.randn(queries, HEADS, DIM, device=DEVICE, dtype=torch.float16)
    # Non-contiguous output view must not touch adjacent storage.
    output_storage = torch.full(
        (queries, HEADS, DIM + 8), 11, device=DEVICE, dtype=torch.float16
    )
    out = output_storage[..., :DIM]
    workspace.run(q, key, value, out, table, length, DIM**-0.5, ks, vs)
    torch.cuda.synchronize()

    selected = torch.tensor(sorted({0, 1, queries // 2, queries - 1}), device=DEVICE)
    pages = table[0].long()
    k = key[pages].reshape(-1, KV_HEADS, data_dim)[:length]
    v = value[pages].reshape(-1, KV_HEADS, data_dim)[:length]
    if packed:
        k = reference.unpack_int4(k, ks[pages].reshape(-1, KV_HEADS)[:length])
        v = reference.unpack_int4(v, vs[pages].reshape(-1, KV_HEADS)[:length])
    else:
        k, v = k.float(), v.float()
        if quantized:
            k *= ks[pages].reshape(-1, KV_HEADS)[:length, :, None]
            v *= vs[pages].reshape(-1, KV_HEADS)[:length, :, None]
    selected_q = q[selected].float()
    if packed:
        selected_q = reference.rht_reference(selected_q).half().float()
    score = torch.einsum(
        "qghd,sgd->qghs",
        selected_q.view(-1, KV_HEADS, HEADS // KV_HEADS, DIM),
        k,
    ) * (DIM**-1.5 if packed else DIM**-0.5)
    mask = (
        torch.arange(length, device=DEVICE)[None, None, None, :]
        > (length - queries + selected)[:, None, None, None]
    )
    score.masked_fill_(mask, -float("inf"))
    expected = torch.einsum("qghs,sgd->qghd", score.softmax(-1), v).reshape(
        -1, HEADS, DIM
    )
    if packed:
        expected = reference.rht_reference(expected, inverse=True)
    actual = out[selected].float()
    if packed:
        # FP16 materialization and SDPA precede the inverse Hadamard. Its
        # cancellation makes element-relative error ill-conditioned near zero;
        # retain the 0.5% budget using each output vector's RMS as the floor.
        error = (actual - expected).abs()
        rms = expected.square().mean(-1, keepdim=True).sqrt()
        bound = 0.0005 + 0.005 * torch.maximum(expected.abs(), rms)
        assert torch.all(error <= bound), (
            f"packed prefill exceeds FP16 error budget: "
            f"{(error / bound).max().item():.6g} times bound"
        )
        assert (actual - expected).norm() <= 0.005 * expected.norm() + 0.0005
    else:
        torch.testing.assert_close(actual, expected, atol=0.0005, rtol=0.005)
    assert torch.all(output_storage[..., DIM:] == 11), "output overrun"
    dtype = "INT4" if packed else "INT8" if quantized else "FP16"
    print(
        f"PASS {dtype} keys={length} queries={queries} block={block_size} error={(actual - expected).abs().max().item():.6g}",
        flush=True,
    )


for quantized in (False, True):
    for length, queries, block_size in (
        (33, 32, 16),
        (1701, 813, 816),
        (8193, 1024, 1024),
        (65537, 256, 816),
        (49, 17, 16),
    ):
        check(length, queries, block_size, quantized)
for length, queries, block_size in (
    (33, 32, 16),
    (1633, 813, 1632),
    (32768, 1024, 1632),
    (262144, 256, 1632),
    (49, 17, 16),
):
    check(length, queries, block_size, True, packed=True)
print("TURING_PREFILL_REFERENCE_PASS")

# Keep the original cases and tolerances above. Additionally exercise the tiled
# implementation through the real paged gather, not only an isolated kernel.
import os
import vllm.v1.attention.ops.turing_prefill_attn as module
from torch.nn.functional import scaled_dot_product_attention as original
from torch.nn.attention import SDPBackend, sdpa_kernel
from torch.nn.attention.bias import causal_lower_right
from vllm.v1.attention.ops.turing_prefill_tiles import load_turing_prefill_tiles

native = module.scaled_dot_product_attention
workspace = TuringPrefillAttention(4096, 4, 256, DEVICE)
torch.manual_seed(1843)
for tokens, queries in ((1633, 17), (4095, 256)):
    block = 128
    pages = (tokens + block - 1) // block
    storage = torch.randn((2, pages, block, 4, 256), device=DEVICE, dtype=torch.float16)
    k, v = storage.unbind(0)
    table = torch.randperm(pages, device=DEVICE, dtype=torch.int32)[None]
    q = torch.randn((queries, 24, 256), device=DEVICE, dtype=torch.float16)
    out = torch.empty_like(q)
    for _ in range(3):
        workspace.run(q, k, v, out, table, tokens, 1 / 16)
    torch.cuda.synchronize()
    graph = torch.cuda.CUDAGraph()
    with torch.cuda.graph(graph):
        workspace.run(q, k, v, out, table, tokens, 1 / 16)
    for _ in range(3):
        q.normal_()
        storage.normal_()
        table.copy_(torch.randperm(pages, device=DEVICE, dtype=torch.int32)[None])
        out.fill_(torch.nan)
        graph.replay()
        actual = out.clone()
        module.scaled_dot_product_attention = original
        try:
            expected = workspace.run(q, k, v, torch.empty_like(out), table, tokens, 1 / 16)
        finally:
            module.scaled_dot_product_attention = native
        torch.testing.assert_close(actual, expected, atol=0.001, rtol=0.01)
    print("PREFILL_GRAPH_REPLAY_PASS", tokens, queries, flush=True)

# Unsupported geometry must preserve the original SDPA contract exactly.
q = torch.randn(2, 4, 17, 128, device=DEVICE, dtype=torch.float16)
k = torch.randn(2, 1, 49, 128, device=DEVICE, dtype=torch.float16).expand(-1, 4, -1, -1)
v = torch.randn_like(k)
mask = causal_lower_right(17, 49)
actual = native(q, k, v, attn_mask=mask, scale=128**-0.5)
expected = original(q, k, v, attn_mask=mask, scale=128**-0.5)
torch.testing.assert_close(actual, expected, atol=0, rtol=0)
assert load_turing_prefill_tiles.cache_info().currsize == 1

q = torch.randn(2, 4, 17, 256, device=DEVICE, dtype=torch.float16)
k = torch.randn(2, 1, 49, 256, device=DEVICE, dtype=torch.float16).expand(-1, 4, -1, -1)
v = torch.randn(2, 1, 49, 256, device=DEVICE, dtype=torch.float16).expand_as(k)
mask = causal_lower_right(17, 49)
previous = os.environ.get("VLLM_TURING_PREFILL_TILE")
os.environ["VLLM_TURING_PREFILL_TILE"] = "0"
try:
    actual = native(q, k, v, attn_mask=mask, scale=1 / 16)
    expected = original(q, k, v, attn_mask=mask, scale=1 / 16)
    torch.testing.assert_close(actual, expected, atol=0, rtol=0)
finally:
    if previous is None:
        os.environ.pop("VLLM_TURING_PREFILL_TILE")
    else:
        os.environ["VLLM_TURING_PREFILL_TILE"] = previous
q.requires_grad_(True)
actual = native(q, k, v, attn_mask=mask, scale=1 / 16)
expected = original(q, k, v, attn_mask=mask, scale=1 / 16)
torch.testing.assert_close(
    torch.autograd.grad(actual.sum(), q)[0],
    torch.autograd.grad(expected.sum(), q)[0], atol=0, rtol=0,
)

# Original CausalBias SDPA itself can reject unaligned storage. Preserve its
# exception rather than weakening that test or silently selecting another path.
q = torch.randn(2, 4, 17, 257, device=DEVICE, dtype=torch.float16)[..., 1:]
try:
    expected = original(q, k, v, attn_mask=mask, scale=1 / 16)
except RuntimeError as expected_error:
    try:
        native(q, k, v, attn_mask=mask, scale=1 / 16)
    except RuntimeError as actual_error:
        assert str(actual_error) == str(expected_error)
    else:
        raise AssertionError("unaligned fallback did not preserve the SDPA error")
else:
    actual = native(q, k, v, attn_mask=mask, scale=1 / 16)
    torch.testing.assert_close(actual, expected, atol=0, rtol=0)
with sdpa_kernel(SDPBackend.MATH):
    hits = load_turing_prefill_tiles.cache_info().hits
    actual = native(q, k, v, attn_mask=mask, scale=1 / 16)
    expected = original(q, k, v, attn_mask=mask, scale=1 / 16)
    assert load_turing_prefill_tiles.cache_info().hits == hits
    torch.testing.assert_close(actual, expected, atol=0, rtol=0)
print("TURING_PREFILL_TILES_REGRESSION_PASS", flush=True)
