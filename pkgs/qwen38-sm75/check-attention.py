#!/usr/bin/env python3
"""Check paged FP16/INT8/INT4 attention against FP32 and live graph replay."""

import itertools
import json
import math
import sys
from types import SimpleNamespace

import numpy as np
import torch
from vllm.v1.attention.ops import spec_decode_attn as spec


D, HK, BLOCK = 256, 4, 832
DEVICE = torch.device("cuda", 0)
ATOL, RTOL, SENTINEL = 5e-4, 5e-3, 11


def rht_reference(x, inverse=False):
    """Independent dense FP32 oracle for the native D256 butterfly."""
    from vllm.v1.attention.ops.int4_per_token_head import _get_rht_signs

    signs = _get_rht_signs(D, 0, x.device)
    if not hasattr(rht_reference, "matrix"):
        h = torch.ones(1, 1, dtype=torch.float32)
        while h.shape[0] < D:
            h = torch.cat((torch.cat((h, h), 1), torch.cat((h, -h), 1)), 0)
        rht_reference.matrix = h.to(x.device)
    if inverse:
        return (x.float() @ rht_reference.matrix) * (signs / D)
    return (x.float() * signs) @ rht_reference.matrix


def unpack_int4(data, packed_scale):
    """Read the bytes, not the original unquantized input, in FP32."""
    bits = packed_scale.contiguous().view(torch.int32)
    scale = (bits & -16).view(torch.float32)
    zero = bits & 15
    values = torch.stack((data & 15, data >> 4), dim=-1).flatten(-2).float()
    return (values - zero[..., None]) * scale[..., None]


def fill_int4_scales(scale):
    # Exercise every zero-point and mantissa-bit combination, including 0/15.
    values = torch.empty(scale.shape, device=scale.device).uniform_(3.0, 7.0)
    zero = torch.arange(scale.numel(), device=scale.device, dtype=torch.int32)
    bits = (values.view(torch.int32) & -16) | ((zero % 16).reshape(scale.shape))
    scale.copy_(bits.view(torch.float32))


class Case:
    def __init__(self, capacities, group, quantized, qmax=16, packed=False):
        self.capacities = capacities
        self.group, self.quantized, self.qmax = group, quantized, qmax
        self.packed = packed
        self.block = 1632 if packed else BLOCK
        self.reqs, self.heads = len(capacities), HK * group
        self.max_blocks = max(1, math.ceil(max(capacities) / self.block))
        self.blocks = self.reqs * self.max_blocks + 2
        self.capacity_q = self.reqs * qmax
        dtype = torch.uint8 if packed else torch.int8 if quantized else torch.float16
        data_dim = D // 2 if packed else D
        # Interleaved K/V, padding within each head, independent scale strides.
        self.cache = torch.empty(
            (self.blocks, self.block, HK, 2, data_dim + 4), dtype=dtype, device=DEVICE
        )
        self.k, self.v = self.cache[..., 0, :data_dim], self.cache[..., 1, :data_dim]
        self.scale_storage = None
        self.ks = self.vs = None
        if packed:
            # The real backend stores each FP32 scale inside the UINT8 head
            # row. Typed views must preserve raw mantissa bits and byte strides.
            self.ks = self.cache[..., 0, data_dim:].view(torch.float32).squeeze(-1)
            self.vs = self.cache[..., 1, data_dim:].view(torch.float32).squeeze(-1)
        elif quantized:
            self.scale_storage = torch.empty(
                (self.blocks, self.block + 3, HK + 1, 3),
                device=DEVICE,
                dtype=torch.float32,
            )
            self.ks = self.scale_storage[:, : self.block, :HK, 0]
            self.vs = self.scale_storage[:, : self.block, :HK, 2]
        self.table_storage = torch.empty(
            (self.reqs, self.max_blocks + 2), device=DEVICE, dtype=torch.int32
        )
        self.table = self.table_storage[:, : self.max_blocks]
        self.q_storage = torch.empty(
            (self.capacity_q + 2, self.heads + 1, D + 4),
            device=DEVICE,
            dtype=torch.float16,
        )
        self.q = self.q_storage[1:-1, : self.heads, :D]
        self.out_storage = torch.empty(
            (self.capacity_q + 2, self.heads + 2, D + 8),
            device=DEVICE,
            dtype=torch.float16,
        )
        self.out = self.out_storage[1:-1, : self.heads, :D]
        self.cuq = torch.empty(self.reqs + 1, device=DEVICE, dtype=torch.int32)
        self.used = torch.empty(self.reqs, device=DEVICE, dtype=torch.int32)
        self.att = spec.SpecDecodeAttention(
            self.reqs, self.heads, D, DEVICE, qmax=qmax, packed_int4=packed
        )
        self.scale = D**-0.5

    def poison_scratch(self):
        self.att.part_o.fill_(torch.nan)
        self.att.part_m.fill_(torch.nan)
        self.att.part_l.fill_(torch.nan)

    def set_state(self, lengths, qlengths, poison=True):
        assert len(lengths) == len(qlengths) == self.reqs
        assert all(
            0 <= q <= min(length, self.qmax) and length <= cap
            for length, q, cap in zip(lengths, qlengths, self.capacities)
        )
        self.lengths, self.qlengths = list(lengths), list(qlengths)
        self.total_q = sum(qlengths)
        self.cuq.copy_(
            torch.tensor(
                [0, *itertools.accumulate(qlengths)], device=DEVICE, dtype=torch.int32
            )
        )
        self.used.copy_(torch.tensor(lengths, device=DEVICE, dtype=torch.int32))
        self.q_storage.fill_(torch.nan)
        self.q[: self.total_q].normal_()
        self.out_storage.fill_(SENTINEL)
        if self.packed:
            self.cache.random_(0, 256)
            fill_int4_scales(self.ks)
            fill_int4_scales(self.vs)
        elif self.quantized:
            self.cache.random_(-127, 128)
            self.scale_storage.uniform_(0.005, 0.015)
        else:
            self.cache.normal_()
        # Every replay remaps pages in place, including spare physical pages.
        order = torch.randperm(self.blocks, device=DEVICE, dtype=torch.int32)
        pages = order[: self.reqs * self.max_blocks].view(self.reqs, self.max_blocks)
        self.table_storage.fill_(-1)
        valid = torch.zeros((self.blocks, self.block), device=DEVICE, dtype=torch.bool)
        slots = torch.arange(self.block, device=DEVICE)
        for req, length in enumerate(lengths):
            count = math.ceil(length / self.block)
            if count:
                self.table[req, :count].copy_(pages[req, :count])
                logical = (
                    torch.arange(count, device=DEVICE)[:, None] * self.block + slots
                )
                valid[pages[req, :count].long()] = logical < length
        # Invalid table columns remain -1. Poison padding in the last real page
        # as well: an unmasked scale/cache load must not silently look like zero.
        invalid = ~valid
        self.cache.masked_fill_(
            invalid[:, :, None, None, None],
            255 if self.packed else -128 if self.quantized else torch.nan,
        )
        if self.quantized:
            self.ks.masked_fill_(invalid[:, :, None], torch.nan)
            self.vs.masked_fill_(invalid[:, :, None], torch.nan)
        if poison:
            self.poison_scratch()

    def args(self, max_query_len=None):
        return (
            self.q,
            self.k,
            self.v,
            self.out,
            self.cuq,
            self.used,
            self.table,
            self.scale,
            self.reqs,
            self.qmax if max_query_len is None else max_query_len,
            self.ks,
            self.vs,
        )

    def check_sentinels(self):
        for guard in (
            self.out_storage[:1],
            self.out_storage[-1:],
            self.out_storage[1:-1, self.heads :, :],
            self.out_storage[1:-1, : self.heads, D:],
            self.out[self.total_q :],
        ):
            assert bool((guard == SENTINEL).all()), (
                "output touched padding/adjacent storage"
            )
        assert bool(torch.isfinite(self.out[: self.total_q]).all()), "non-finite output"

    def reference_error(self):
        # FP32 GQA oracle, not SDPA and not the native kernel's half-rounded
        # intermediates. Match check-prefill.py tolerances, without loosening.
        # Only ONE KV head and ONE query score matrix live at once. No sixfold
        # KV repeat, no CPU cache copy, and no all-query long-context score tensor.
        maximum = 0.0
        offset = 0
        for req, (length, queries) in enumerate(zip(self.lengths, self.qlengths)):
            if not queries:
                continue
            pages = self.table[req, : math.ceil(length / self.block)].long()
            positions = torch.arange(length, device=DEVICE)
            for kvh in range(HK):
                data_dim = D // 2 if self.packed else D
                k = self.k[pages, :, kvh, :].reshape(-1, data_dim)[:length]
                v = self.v[pages, :, kvh, :].reshape(-1, data_dim)[:length]
                if self.packed:
                    k = unpack_int4(k, self.ks[pages, :, kvh].reshape(-1)[:length])
                    v = unpack_int4(v, self.vs[pages, :, kvh].reshape(-1)[:length])
                else:
                    k, v = k.float(), v.float()
                    if self.quantized:
                        k.mul_(self.ks[pages, :, kvh].reshape(-1)[:length, None])
                        v.mul_(self.vs[pages, :, kvh].reshape(-1)[:length, None])
                heads = slice(kvh * self.group, (kvh + 1) * self.group)
                for qi in range(queries):
                    q = self.q[offset + qi, heads].float()
                    if self.packed:
                        q = rht_reference(q).half().float()
                    score = torch.einsum("gd,sd->gs", q, k) * (
                        self.scale / D if self.packed else self.scale
                    )
                    score.masked_fill_(
                        positions[None, :] > length - queries + qi, -torch.inf
                    )
                    expected = torch.einsum("gs,sd->gd", score.softmax(-1), v)
                    if self.packed:
                        expected = rht_reference(expected, inverse=True)
                    actual = self.out[offset + qi, heads].float()
                    error = (actual - expected).abs().max().item()
                    maximum = max(maximum, error)
                    try:
                        torch.testing.assert_close(
                            actual, expected, atol=ATOL, rtol=RTOL
                        )
                    except AssertionError as exc:
                        raise AssertionError(
                            f"request={req} query={qi} kvhead={kvh} "
                            f"max_abs={error:.6g}: {exc}"
                        ) from exc
                del k, v
            offset += queries
        return maximum

    def verify(self, label):
        self.check_sentinels()
        error = self.reference_error()
        print(
            json.dumps(
                dict(
                    status="PASS",
                    case=label,
                    dtype="INT4"
                    if self.packed
                    else "INT8"
                    if self.quantized
                    else "FP16",
                    G=self.group,
                    lengths=self.lengths,
                    queries=self.qlengths,
                    max_abs=error,
                )
            ),
            flush=True,
        )


def capture(fn):
    # Lazy extension loading and Triton compilation happen before capture.
    stream = torch.cuda.Stream()
    stream.wait_stream(torch.cuda.current_stream())
    with torch.cuda.stream(stream):
        for _ in range(3):
            fn()
    torch.cuda.current_stream().wait_stream(stream)
    graph = torch.cuda.CUDAGraph()
    with torch.cuda.graph(graph):
        fn()
    return graph


def check_static(quantized):
    # Pairwise coverage, not a length x query-count x G Cartesian product.
    fixtures = (
        (1, 1, 6),
        (31, 2, 4),
        (32, 5, 6),
        (33, 8, 6),
        (832, 5, 4),
        (833, 2, 6),
        (1500, 16, 6),
        (8193, 8, 6),
        (32768, 5, 6),
        (131072, 5, 6),
    )
    for length, queries, group in fixtures:
        case = Case([length], group, quantized)
        case.set_state([length], [queries])
        case.att.run(*case.args(queries))
        case.verify("eager")
        del case


def check_graph(quantized):
    case = Case([8193, 833, 33], 4 if quantized else 6, quantized)
    states = (
        ([8193, 833, 0], [8, 2, 0]),
        ([33, 1, 0], [2, 1, 0]),
        ([832, 31, 0], [5, 2, 0]),
        ([1, 833, 0], [1, 8, 0]),
        ([0, 32, 33], [0, 5, 2]),
        ([0, 0, 0], [0, 0, 0]),
        ([8193, 833, 33], [8, 1, 5]),
    )
    case.set_state(*states[0])
    graph = capture(lambda: case.att.run(*case.args()))
    for index, (lengths, queries) in enumerate(states):
        # Alternate NaN scratch with real prior-run scratch. In particular the
        # first shortening replay retains the previous long-context partials.
        case.set_state(lengths, queries, poison=index % 2 == 0)
        graph.replay()
        case.verify(f"graph-replay-{index}")
    del graph, case


def check_packed():
    # Nibble order, inline scale bits, RHT normalization, page boundaries,
    # GQA tile padding and the native262144 cache geometry.
    for length, queries, group in (
        (1, 1, 6),
        (33, 8, 6),
        (1632, 5, 4),
        (1633, 2, 6),
        (32768, 5, 6),
        (262144, 5, 6),
    ):
        case = Case([length], group, True, packed=True)
        case.set_state([length], [queries])
        case.att.run(*case.args(queries))
        case.verify("packed-eager")
        del case

    case = Case([8193, 1633, 33], 6, True, packed=True)
    states = (
        ([8193, 1633, 0], [8, 2, 0]),
        ([33, 1, 0], [2, 1, 0]),
        ([1632, 31, 0], [5, 2, 0]),
        ([0, 1633, 33], [0, 5, 2]),
        ([0, 0, 0], [0, 0, 0]),
        ([8193, 1633, 33], [8, 1, 5]),
    )
    case.set_state(*states[0])
    graph = capture(lambda: case.att.run(*case.args()))
    for index, state in enumerate(states):
        case.set_state(*state, poison=index % 2 == 0)
        graph.replay()
        case.verify(f"packed-graph-{index}")
    del graph, case

    # Exercise the real RHT+packing writer, including its negative-slot padding,
    # then compare attention against the resulting bytes rather than FP16 KV.
    from vllm.v1.attention.ops.int4_per_token_head import reshape_and_cache_int4

    case = Case([33], 6, True, packed=True)
    case.set_state([33], [5])
    key = torch.randn(34, HK, D, device=DEVICE, dtype=torch.float16)
    value = torch.randn_like(key)
    key[-1].fill_(torch.nan)
    value[-1].fill_(torch.nan)
    slots = torch.full((34,), -1, device=DEVICE, dtype=torch.int64)
    slots[:33] = case.table[0, 0].long() * case.block + torch.arange(33, device=DEVICE)
    reshape_and_cache_int4(
        key,
        value,
        case.k,
        case.v,
        slots,
        k_scale_cache=case.ks,
        v_scale_cache=case.vs,
    )
    case.att.run(*case.args(5))
    case.verify("packed-real-writer")


def check_prefill_dispatch():
    from vllm.v1.worker.gpu_model_runner import GPUModelRunner

    runner = GPUModelRunner.__new__(GPUModelRunner)
    # These shapes all fit the MTP4 graph. Prompt state must decide eligibility.
    cases = (
        ("fresh", [0], [5], 1, False),
        ("prefill-tail", [832], [837], 1, False),
        ("mixed", [5, 832], [5, 837], 2, False),
        ("decode-with-padding", [5, 0], [5, 100], 1, True),
    )
    for label, computed, prompts, count, expected in cases:
        runner.input_batch = SimpleNamespace(
            num_computed_tokens_cpu=np.array(computed),
            num_prompt_tokens=np.array(prompts),
        )
        args = dict(
            max_num_scheduled_tokens=5,
            uniform_decode_query_len=5,
            num_tokens=5 * count,
            num_reqs=count,
        )
        assert runner._is_uniform_decode(**args) == expected, label
        assert runner._is_uniform_decode(**args, force_uniform_decode=True)
        assert not runner._is_uniform_decode(**args, force_uniform_decode=False)
    print("PREFILL_GRAPH_DISPATCH_PASS", flush=True)


def main():
    torch.manual_seed(417)
    torch.set_grad_enabled(False)
    torch.backends.cuda.matmul.allow_tf32 = False
    torch.set_float32_matmul_precision("highest")
    check_prefill_dispatch()
    for quantized in (False, True):
        check_static(quantized)
        check_graph(quantized)
    check_packed()
    print("ATTENTION_REFERENCE_AND_LIVE_GRAPH_PASS", flush=True)

    # Also exercise the native Ninja/shell/CUDA linker path used by the runtime.
    import flashinfer

    torch.manual_seed(915)
    logits = torch.randn(8, 248320, device="cuda")
    values, indices = flashinfer.top_k(logits, 64, sorted=True, deterministic=True)
    expected = torch.topk(logits, 64).values
    torch.testing.assert_close(values, expected)
    torch.testing.assert_close(logits.gather(1, indices.long()), expected)
    print("NATIVE_SELECTOR_JIT_PASS")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(
            f"ATTENTION_CHECK_FAIL: {type(exc).__name__}: {exc}",
            file=sys.stderr,
            flush=True,
        )
        raise
