#!/usr/bin/env python3
"""Check native SM75 GDN state against FLA, including chained state and graphs."""

import gc
import json
import os
from unittest.mock import patch
import torch
from vllm.third_party.flash_linear_attention.ops import turing_gdn


def emit(**fields):
    print(json.dumps(fields), flush=True)


def timing(fn, reps=8):
    for _ in range(2):
        fn()
    start, end = torch.cuda.Event(enable_timing=True), torch.cuda.Event(
        enable_timing=True
    )
    start.record()
    for _ in range(reps):
        fn()
    end.record()
    end.synchronize()
    return start.elapsed_time(end) / reps


from vllm.third_party.flash_linear_attention.ops.chunk_delta_h import (
    chunk_gated_delta_rule_fwd_h,
)
from vllm.third_party.flash_linear_attention.ops.chunk_scaled_dot_kkt import (
    chunk_scaled_dot_kkt_fwd,
)
from vllm.third_party.flash_linear_attention.ops.cumsum import chunk_local_cumsum
from vllm.third_party.flash_linear_attention.ops.solve_tril import solve_tril
from vllm.third_party.flash_linear_attention.ops.wy_fast import recompute_w_u_fwd
from vllm.third_party.flash_linear_attention.ops.index import (
    prepare_chunk_indices,
    prepare_chunk_offsets,
)

native = turing_gdn.load_turing_gdn()


def compare(actual, expected, label):
    for name, a, b in zip(("h", "v_new", "final_state"), actual, expected):
        delta = a.float() - b.float()
        rms = (
            (delta.square().mean() / b.float().square().mean().clamp_min(1e-16))
            .sqrt()
            .item()
        )
        maximum = delta.abs().max().item()
        emit(
            kind="correctness",
            label=label,
            tensor=name,
            relative_rms=rms,
            max_abs=maximum,
        )
        assert a.isfinite().all(), (label, name, "nonfinite")
        assert rms < 0.004, (label, name, rms, maximum)
        torch.testing.assert_close(a.float(), b.float(), atol=0.008, rtol=0.025)


RANDOM_STATE = object()


def fixture(
    lengths, seed=913, strided=False, fp32_state=False, initial_state=RANDOM_STATE
):
    torch.manual_seed(seed)
    t = sum(lengths)
    n = len(lengths)
    h = 48
    hg = 16
    d = 128
    k = torch.nn.functional.normalize(
        torch.randn(1, t, hg, d, device="cuda"), dim=-1
    ).half()
    v = torch.randn(1, t, h, d, device="cuda", dtype=torch.float16)
    beta = torch.rand(1, t, h, device="cuda")
    g = -torch.rand_like(beta) * 0.05
    h0 = (
        torch.randn(
            n,
            h,
            d,
            d,
            device="cuda",
            dtype=torch.float32 if fp32_state else torch.float16,
        )
        * 0.1
        if initial_state is RANDOM_STATE
        else initial_state
    )
    cu = torch.tensor(
        [0] + list(__import__("itertools").accumulate(lengths)),
        device="cuda",
        dtype=torch.int32,
    )
    ci = prepare_chunk_indices(cu, 64)
    co = prepare_chunk_offsets(cu, 64)
    common = dict(cu_seqlens=cu, chunk_indices=ci)
    g = chunk_local_cumsum(g, chunk_size=64, **common)
    a = chunk_scaled_dot_kkt_fwd(
        k=k, beta=beta, g=g, output_dtype=torch.float32, **common
    )
    solved = solve_tril(A=a, output_dtype=k.dtype, **common)
    w, u = recompute_w_u_fwd(k=k, v=v, beta=beta, A=solved, g_cumsum=g, **common)
    if strided:

        def stride(x):
            if x is None:
                return None
            storage = torch.full(
                (*x.shape[:-1], x.shape[-1] * 2),
                float("nan"),
                device="cuda",
                dtype=x.dtype,
            )
            view = storage[..., : x.shape[-1]]
            view.copy_(x)
            return view

        k, w, u, h0 = map(stride, (k, w, u, h0))
        storage = torch.full((1, t, h * 2), float("nan"), device="cuda", dtype=g.dtype)
        view = storage[:, :, :h]
        view.copy_(g)
        g = view
    # The upstream kernel assumes contiguous logical storage. Compare padded
    # native views to equivalent contiguous values, never to its invalid reads.
    rk, rw, ru, rg, rh0 = (
        x.contiguous() if x is not None else None for x in (k, w, u, g, h0)
    )
    baseline = lambda: chunk_gated_delta_rule_fwd_h(
        k=rk,
        w=rw,
        u=ru,
        g=rg,
        initial_state=rh0,
        output_final_state=True,
        chunk_offsets=co,
        **common,
    )
    trial = lambda: native(k, w, u, g, h0, cu, co, len(ci))
    return baseline, trial, (k, w, u, g, h0, cu, co)


with torch.inference_mode():
    for lengths, strided, fp32 in [
        ([1], False, False),
        ([5], True, False),
        ([63], False, True),
        ([64], True, True),
        ([65], False, False),
        ([63, 97], True, False),
        ([1632], False, False),
        ([3264], False, False),
    ]:
        label = f"{lengths}-strided{strided}-fp32{fp32}"
        baseline, trial, inputs = fixture(lengths, strided=strided, fp32_state=fp32)
        expected = baseline()
        actual = trial()
        torch.cuda.synchronize()
        compare(actual, expected, label)
        if sum(lengths) >= 1632:
            emit(
                kind="timing",
                label=label,
                baseline_ms=timing(baseline),
                native_ms=timing(trial),
            )
        if lengths == [1632]:
            stream = torch.cuda.Stream()
            stream.wait_stream(torch.cuda.current_stream())
            with torch.cuda.stream(stream):
                trial()
            torch.cuda.current_stream().wait_stream(stream)
            graph = torch.cuda.CUDAGraph()
            with torch.cuda.graph(graph):
                captured = trial()
            for seed in (17, 29):
                _, _, replacement = fixture(lengths, seed=seed)
                for dest, source in zip(inputs, replacement):
                    dest.copy_(source)
                graph.replay()
                torch.cuda.synchronize()
                compare(captured, baseline(), f"graph-replay-{seed}")
            emit(kind="graph_timing", native_ms=timing(graph.replay, reps=32))
            del graph, captured, replacement
        del baseline, trial, inputs, actual, expected
        gc.collect()
        torch.cuda.empty_cache()
    for lengths in ([1], [65], [63, 97], [1632]):
        baseline, trial, inputs = fixture(lengths, strided=True, initial_state=None)
        expected = baseline()
        actual = trial()
        torch.cuda.synchronize()
        compare(actual, expected, f"no-initial-state-{lengths}")
        del baseline, trial, inputs, actual, expected
        gc.collect()
        torch.cuda.empty_cache()
    reference_state = trial_state = None
    for step in range(8):
        baseline, _, inputs = fixture(
            [4096], seed=100 + step, initial_state=reference_state
        )
        k, w, u, g, _, cu, co = inputs
        expected = baseline()
        actual = native(k, w, u, g, trial_state, cu, co, 64)
        torch.cuda.synchronize()
        compare(actual, expected, f"continuation-{(step+1)*4096}")
        reference_state = expected[2].half()
        trial_state = actual[2].half()
        del baseline, inputs, actual, expected, k, w, u, g, cu, co
    baseline, trial, inputs = fixture([65])
    k, w, u, g, h0, cu, co = inputs
    actual = turing_gdn.chunk_gated_delta_rule_fwd_h(
        k,
        w,
        u,
        g,
        initial_state=h0,
        output_final_state=True,
        cu_seqlens=cu,
        chunk_offsets=co,
    )
    compare(actual, baseline(), "dispatch")
    without_final = turing_gdn.chunk_gated_delta_rule_fwd_h(
        k, w, u, g, initial_state=h0, cu_seqlens=cu, chunk_offsets=co
    )
    assert without_final[2] is None
    with patch.dict(os.environ, {"VLLM_TURING_GDN_STATE": "0"}), patch.object(
        turing_gdn, "reference_state", wraps=turing_gdn.reference_state
    ) as reference:
        actual = turing_gdn.chunk_gated_delta_rule_fwd_h(
            k,
            w,
            u,
            g,
            initial_state=h0,
            output_final_state=True,
            cu_seqlens=cu,
            chunk_offsets=co,
        )
        assert reference.call_count == 1
        compare(actual, baseline(), "disabled-native-fallback")
    emit(kind="complete", peak_allocated=torch.cuda.max_memory_allocated())
    print("TURING_GDN_REFERENCE_PASS", flush=True)
