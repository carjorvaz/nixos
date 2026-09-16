#!/usr/bin/env python3
"""Build the 40k-token int4 draft head for the uncensored checkpoint.

The uncensored model ships an int8, full-vocabulary lm_head and a bf16 MTP
module. Every MTP draft pass therefore reads ~1.27 GB of int8 lm_head instead
of the fast variant's 40k-row int4 draft head (~110 MB), which is the bulk of
its ~30% decode deficit. This script slices the uncensored lm_head rows named
by the shipped draft vocabulary, requantizes them to int4 group-128 (RTN) and
publishes a hybrid copy of the checkpoint whose extra-tensors file carries
`mtp.draft_lm_head.*`. Speculation stays exact: the target verifies every
draft; only acceptance can change.

The source checkpoint is never modified. Hard-link the directory first:

    cp -al UNSRC HYBRID
    python build-draft-head.py UNSRC HYBRID FAST_TARGET 8

The working configuration is an int8 head (`8`): it copies the source int8
rows exactly, preserves acceptance, and is what the uncensored unit serves.
`4` builds an int4 head (12.9% relative RMS on sampled rows, acceptance
untested) and `mtp_bits=4` additionally requantizes the MTP matrices and is what the
uncensored unit ships (int8 head + int4 MTP). Two traps: the mtp group must
exclude `mtp.embed_tokens` (it is loaded from the target's int8 embedding),
and an int4 draft head additionally needs the `lm_head` group narrowed away
from it (the shipped `re:.*lm_head$` target also matches
`mtp.draft_lm_head`, so the head silently stays int8-shaped).
"""

import json
import math
import os
import struct
import sys
from pathlib import Path

import torch
from compressed_tensors.compressors.pack_quantized.helpers import (
    pack_to_int32,
    unpack_from_int32,
)
from safetensors import safe_open


BYTES = {"I32": 4, "I64": 8, "F16": 2, "BF16": 2, "F32": 4, "I8": 1, "U8": 1}


def write_text_atomic(path, text):
    """Write via a temporary file: hard-linked directories must not share edits."""
    path = Path(path)
    part = path.with_name(path.name + ".part")
    part.write_text(text)
    os.replace(part, path)


def read_header(path):
    with open(path, "rb") as stream:
        length = struct.unpack("<Q", stream.read(8))[0]
        header = json.loads(stream.read(length))
    return header, 8 + length


def tensor_bytes(tensor):
    return tensor.contiguous().view(torch.uint8).numpy().tobytes()


def rewrite_safetensors(src, dst, new, drop=()):
    """Copy every tensor of *src* verbatim except *drop*, and append *new*."""
    header, data_start = read_header(src)
    drop = set(drop)
    layout = {
        name: dict(entry)
        for name, entry in header.items()
        if name != "__metadata__" and name not in drop
    }
    for name, (tensor, dtype) in new.items():
        layout[name] = {"dtype": dtype, "shape": list(tensor.shape)}
    offset = 0
    for name in sorted(layout):
        entry = layout[name]
        count = math.prod(entry["shape"])
        size = count * BYTES[entry["dtype"]]
        entry["data_offsets"] = [offset, offset + size]
        offset += size
    layout["__metadata__"] = header.get("__metadata__") or {"format": "pt"}
    encoded = json.dumps(layout, sort_keys=True, separators=(",", ":")).encode()
    encoded += b" " * (-len(encoded) % 8)
    out_start = 8 + len(encoded)
    part = Path(str(dst) + ".part")
    with open(src, "rb") as source, open(part, "wb") as output:
        output.write(struct.pack("<Q", len(encoded)))
        output.write(encoded)
        output.truncate(out_start + offset)
        for name, entry in header.items():
            if name == "__metadata__" or name in drop:
                continue
            begin, end = entry["data_offsets"]
            source.seek(data_start + begin)
            output.seek(out_start + layout[name]["data_offsets"][0])
            remaining = end - begin
            while remaining:
                block = source.read(min(8 << 20, remaining))
                if not block:
                    raise OSError("Truncated source tensor")
                output.write(block)
                remaining -= len(block)
        for name, (tensor, _) in new.items():
            output.seek(out_start + layout[name]["data_offsets"][0])
            output.write(tensor_bytes(tensor))
        output.flush()
        os.fsync(output.fileno())
    os.replace(part, dst)


def requantize_matrix(tensor, bits):
    """Symmetric group-128 RTN quantization of a 2-D weight tensor."""
    rows, cols = tensor.shape
    if cols % 128:
        raise ValueError(f"Columns not group-128 aligned: {tuple(tensor.shape)}")
    groups = tensor.to(torch.float32).reshape(rows, cols // 128, 128)
    scale = groups.abs().amax(dim=-1, keepdim=True).clamp_min(1e-10) / 7.0
    q = torch.round(groups / scale).clamp(-8, 7).to(torch.int8).reshape(rows, cols)
    return pack_to_int32(q, bits), scale.squeeze(-1).to(torch.float16)


def build(unsrc, hybrid, fast, bits=8, mtp_bits=0):
    unsrc, hybrid, fast = Path(unsrc), Path(hybrid), Path(fast)
    ids = torch.load(fast / "mtp_draft_vocab_ids.pt", map_location="cpu").to(torch.int64)
    rows = int(ids.numel())
    index = json.loads((unsrc / "model.safetensors.index.json").read_text())["weight_map"]
    shard = index["lm_head.weight_packed"]
    with safe_open(unsrc / shard, framework="pt", device="cpu") as handle:
        packed = handle.get_slice("lm_head.weight_packed")
        scales = handle.get_slice("lm_head.weight_scale")
        source_rows = packed.get_shape()[0]
        cols = packed.get_shape()[1] * 4
        groups = scales.get_shape()[1]
        # bits=8 copies the source int8 rows (no extra quantization error);
        # bits=4 requantizes them to int4 group-128 RTN.
        packed_out = torch.zeros(
            (rows, cols // (32 // bits)), dtype=torch.int32
        )
        scale_out = torch.zeros((rows, groups), dtype=torch.float16)
        # Walk the source in contiguous row blocks: the draft rows are a
        # scattered selection, so a per-row gather would materialize the whole
        # 1.3 GB tensor. Each block is small and the selection inside it is a
        # sorted contiguous range.
        sorted_ids, order = torch.sort(ids)
        block = 4096
        for start in range(0, source_rows, block):
            stop = min(start + block, source_rows)
            lo = int(torch.searchsorted(sorted_ids, start))
            hi = int(torch.searchsorted(sorted_ids, stop))
            if lo == hi:
                continue
            selected = sorted_ids[lo:hi]
            local = selected - start
            chunk = packed[start:stop].to(torch.int32)
            chunk_scale = scales[start:stop]
            n = selected.numel()
            q8 = unpack_from_int32(chunk[local], 8, torch.Size([n, cols]))
            if bits == 8:
                packed_out[order[lo:hi]] = pack_to_int32(q8, 8)
                scale_out[order[lo:hi]] = chunk_scale[local]
            else:
                w = q8.to(torch.float32) * chunk_scale[local].float().repeat_interleave(
                    cols // groups, dim=1
                )
                grouped = w.reshape(n, groups, cols // groups)
                scale4 = grouped.abs().amax(dim=-1, keepdim=True).clamp_min(1e-10) / 7.0
                q4 = torch.round(grouped / scale4).clamp(-8, 7).to(torch.int8).reshape(n, cols)
                packed_out[order[lo:hi]] = pack_to_int32(q4, 4)
                scale_out[order[lo:hi]] = scale4.squeeze(-1).to(torch.float16)
            if start % (block * 16) == 0:
                print(f"scanned {stop}/{source_rows}", flush=True)
    shape = torch.tensor([rows, cols], dtype=torch.int64)
    extras = hybrid / "model_extra_tensors.safetensors"
    new_tensors = {
        "mtp.draft_lm_head.weight_packed": (packed_out, "I32"),
        "mtp.draft_lm_head.weight_scale": (scale_out, "F16"),
        "mtp.draft_lm_head.weight_shape": (shape, "I64"),
    }
    drop = set()
    if mtp_bits:
        # The MTP module is read on every draft pass; quantizing its nine
        # matrices from bf16 to int4 (+~215 MB instead of ~850 MB) is the same
        # trade the fast variant ships, and speculation stays exact.
        with safe_open(extras, framework="pt", device="cpu") as handle:
            for name in list(handle.keys()):
                if not name.startswith("mtp.") or name.startswith("mtp.draft_lm_head"):
                    continue
                tensor = handle.get_tensor(name)
                if tensor.ndim != 2:
                    continue
                packed_m, scale_m = requantize_matrix(tensor, mtp_bits)
                stem = name.removesuffix(".weight")
                new_tensors[f"{stem}.weight_packed"] = (packed_m, "I32")
                new_tensors[f"{stem}.weight_scale"] = (scale_m, "F16")
                new_tensors[f"{stem}.weight_shape"] = (
                    torch.tensor(tensor.shape, dtype=torch.int64),
                    "I64",
                )
                drop.add(name)
                print(f"mtp int4: {name} {tuple(tensor.shape)}", flush=True)
    rewrite_safetensors(extras, extras, new_tensors, drop)
    # Index: register the new tensors and drop the replaced full-precision ones.
    updated = json.loads((unsrc / "model.safetensors.index.json").read_text())
    for suffix in ("weight_packed", "weight_scale", "weight_shape"):
        updated["weight_map"][f"mtp.draft_lm_head.{suffix}"] = "model_extra_tensors.safetensors"
    for name in drop:
        updated["weight_map"].pop(name, None)
        stem = name.removesuffix(".weight")
        for suffix in ("weight_packed", "weight_scale", "weight_shape"):
            updated["weight_map"][f"{stem}.{suffix}"] = "model_extra_tensors.safetensors"
    write_text_atomic(
        hybrid / "model.safetensors.index.json",
        json.dumps(updated, sort_keys=True, indent=2) + "\n",
    )
    # Quantization: the draft head is a new int4 group; the bf16 MTP weights and
    # the int8 target lm_head keep their existing groups.
    group = {
        "format": "pack-quantized",
        "input_activations": None,
        "output_activations": None,
        "targets": ["re:^mtp\\.draft_lm_head$"],
        "weights": {
            "actorder": None,
            "block_structure": None,
            "dynamic": False,
            "group_size": 128,
            "num_bits": bits,
            "observer": "memoryless_minmax",
            "observer_kwargs": {},
            "scale_dtype": None,
            "strategy": "group",
            "symmetric": True,
            "type": "int",
            "zp_dtype": None,
        },
    }
    for name in ("config.json", "quantization_config.json"):
        path = unsrc / name
        if not path.exists():
            continue
        config = json.loads(path.read_text())
        container = config.get("quantization_config", config)
        groups = container.setdefault("config_groups", {})
        groups["group_3_draft_head"] = group
        if mtp_bits:
            import copy as _copy
            mtp_group = _copy.deepcopy(group)
            mtp_group["targets"] = ["re:^mtp\\.(fc|layers\\..*)$"]
            mtp_group["weights"]["num_bits"] = mtp_bits
            groups["group_4_mtp"] = mtp_group
        write_text_atomic(hybrid / name, json.dumps(config, indent=2) + "\n")
    print("draft head ready", flush=True)


if __name__ == "__main__":
    if len(sys.argv) not in (4, 5, 6):
        raise SystemExit(__doc__)
    bits = int(sys.argv[4]) if len(sys.argv) >= 5 else 8
    mtp_bits = int(sys.argv[5]) if len(sys.argv) == 6 else 0
    build(sys.argv[1], sys.argv[2], sys.argv[3], bits, mtp_bits)
