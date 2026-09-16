"""Reconstruct the pinned fast checkpoint; never modify the BF16 source shard.

Only the embedding is derived locally, using upstream prepare/quant_embed.py's
int8/group-128 recipe. Downloads and tensor IO are bounded, resumable downloads
are verified before publication, and the readiness manifest is committed last.
"""

import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import struct
import sys
from urllib.error import HTTPError
from urllib.request import Request, urlopen


# Git-hosted files use Git blob SHA-1, LFS objects use SHA-256. These inventories
# come from the HF revision API with blobs=true, not mutable branch names.
PINS = {
    "base": ("dbirks/Qwen3.8-27B-W4A16-AutoRound", "1f05c441c4e64ae0549de44fa9ea5a6d43610314"),
    "fast": ("syvai/qwen3.8-27b-3090-fast-variant", "124c14e7e8c7d2f5402933b9af368e772a9fcf0c"),
    "drafter": ("syvai/Qwen3.8-27B-DFlash2-W4A16", "4d30ec736ffc6b8688dc2ae2b502d9b48bdec279"),
}
ASSETS = {
    "base": {
        "model-00001-of-00007.safetensors": (3211003472, "6b2adc4f1b93386eedd033a62c63221bf85e789c09ada8ff43939c55e9f06250"),
        "model-00002-of-00007.safetensors": (3195027104, "a223fa487834749a14d86d558af9a4d5799b79be9bc28bdefa43eed055d10578"),
        "model-00003-of-00007.safetensors": (3195027104, "8719567ac822768ac61872894604d3a4d13f2edbd22c9bd3c4680ebc83e24ca5"),
        "model-00004-of-00007.safetensors": (3217442568, "8faf8d4a57c69b9b96e27c4eabf1ba0caadd3d48344d6f65df17f30da2a7e6e3"),
        "model-00005-of-00007.safetensors": (699275200, "0994bb8d91c07ceefc4bfffd3a7b7fd110cc9bd3ce865bdcb2821abf02a02fab"),
        "model-00006-of-00007.safetensors": (2542807272, "55a14ee79d3e5a65a8731d89426f4df477e8bdc7daa7976d41254d8afb9432f0"),
        "chat_template.jinja": (8952, "c0c686f9c38d70d179fb7b5f5aa7530bc913dda3"),
        "generation_config.json": (219, "3ef979b678c8e828c637b6437b6db4c3b2962db1"),
        "processor_config.json": (1191, "33818c7f9e991ad735fd240209f4fa73e6c28c50"),
        "tokenizer.json": (19989325, "06b9509352d2af50381ab2247e083b80d32d5c0aba91c272ca9ff729b6a0e523"),
        "tokenizer_config.json": (1166, "b4acebe045132228e18a4e2ca7f75ce137d1fbf7"),
    },
    "fast": {
        "config.json": (17060, "74eae7c065fe24dcbe16d30ec9e89589d147a9d9"),
        "draft_vocab_ids.json": (279256, "d0069e09dabd05c6b84662cb4ac30210c365269e"),
        "model-00007-of-00007.safetensors": (655565120, "ac4511ddfbdcd8399dffee570c31708c13f974a18e46d3c337ca652a46a1a437"),
        "model.safetensors.index.json": (200180, "1f1321de4c72dbac167cd9ad9b8ca0fecdc8cba0"),
        "model_extra_tensors.safetensors": (327162544, "3643128012845562d066540990eceb012e6dc9d1ba794c668d774a91edcd9dbb"),
        "mtp_draft_vocab_ids.pt": (329341, "8af9028616e41932e0c949cd5364d2da0a69d15375af9bb404cab1e4d723f581"),
    },
    "drafter": {
        "config.json": (2264, "f3c6e6c3d2a45a5795754fd8b10658ad6c496e36"),
        "model.safetensors": (1280633960, "ec26996e6a0745ab5edb857117220ce1e219ad524f71e6e149b703804947d8e7"),
    },
}
EMBED_SHARD = "model-00006-of-00007.safetensors"
BLOCK = 256
IO_SIZE = 4 * 1024 * 1024
RECIPE = {
    "version": 1, "upstream_revision": "18349177b7962ef1d699dc154844f9c04317a474",
    "bits": 8, "group_size": 128, "qmin": -128, "qmax": 127,
    "scale_min": 1e-10, "scale_dtype": "BF16", "packed_dim": 1,
    "rounding": "torch.round", "row_block": BLOCK,
}


def digest_file(path, expected=None):
    """Return SHA-256; if supplied, check size and pinned Git/LFS identity too."""
    size = path.stat().st_size
    if expected is not None and size != expected[0]:
        raise ValueError(f"Wrong size: {path}")
    sha = hashlib.sha256()
    git = hashlib.sha1(f"blob {size}\0".encode()) if expected and len(expected[1]) == 40 else None
    with path.open("rb") as stream:
        while chunk := stream.read(IO_SIZE):
            sha.update(chunk)
            if git is not None:
                git.update(chunk)
    if expected and (git or sha).hexdigest() != expected[1]:
        raise ValueError(f"Checksum mismatch: {path}")
    return {"size": size, "sha256": sha.hexdigest()}


def verified(path, expected):
    try:
        return digest_file(path, expected)
    except (FileNotFoundError, ValueError):
        return None


def sync_directory(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def commit(part, destination):
    with part.open("rb") as stream:
        os.fsync(stream.fileno())
    os.replace(part, destination)
    sync_directory(destination.parent)


def write_json(path, value):
    part = path.with_name(path.name + ".part")
    part.unlink(missing_ok=True)
    part.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")
    commit(part, path)


def fetch(models, family, name):
    """A .part is only progress, never evidence; verify the entire resumed file."""
    from huggingface_hub import hf_hub_url
    from huggingface_hub.utils import build_hf_headers

    repo, revision = PINS[family]
    expected = ASSETS[family][name]
    destination = models / "sources" / family / revision / name
    destination.parent.mkdir(parents=True, exist_ok=True)
    if record := verified(destination, expected):
        return destination, record
    part = destination.with_name(name + ".part")
    # Existing model directories are optional seeds, including pristine backups.
    # Hard links are never edited or chmod'ed; a bad destination is replaced.
    for seed in models.rglob(name + "*"):
        if seed == destination or seed == part or not seed.is_file() or seed.name.endswith(".part"):
            continue
        if record := verified(seed, expected):
            part.unlink(missing_ok=True)
            os.link(seed.resolve(), part)
            commit(part, destination)
            return destination, record
    if part.is_symlink() or (part.exists() and part.stat().st_size > expected[0]):
        part.unlink()
    for attempt in range(2):
        offset = part.stat().st_size if part.exists() else 0
        try:
            if offset < expected[0]:
                headers = build_hf_headers(token=False)
                headers["Accept-Encoding"] = "identity"
                if offset:
                    headers["Range"] = f"bytes={offset}-"
                url = hf_hub_url(repo, name, revision=revision)
                print(f"Fetching {family}/{name} ({offset}/{expected[0]} bytes)", flush=True)
                with urlopen(Request(url, headers=headers), timeout=120) as response:
                    status = response.status
                    if status == 206:
                        match = re.fullmatch(r"bytes (\d+)-(\d+)/(\d+)", response.headers.get("Content-Range", ""))
                        if not match or tuple(map(int, match.groups())) != (offset, expected[0] - 1, expected[0]):
                            raise ValueError(f"Invalid download range: {name}")
                    elif status == 200:
                        offset = 0  # Ignored Range: replace, never append the full body.
                    else:
                        raise ValueError(f"Unexpected HTTP status {status}: {name}")
                    remaining = expected[0] - offset
                    length = response.headers.get("Content-Length")
                    if length is not None and int(length) != remaining:
                        raise ValueError(f"Invalid download length: {name}")
                    with part.open("ab" if offset else "wb") as output:
                        while remaining:
                            chunk = response.read(min(IO_SIZE, remaining))
                            if not chunk:
                                raise OSError(f"Interrupted download: {name}; rerun to resume")
                            output.write(chunk)
                            remaining -= len(chunk)
                        if response.read(1):
                            raise ValueError(f"Oversized download: {name}")
            record = digest_file(part, expected)
        except HTTPError as error:
            if error.code != 416:
                raise
            part.unlink(missing_ok=True)
            if attempt:
                raise
        except ValueError:
            part.unlink(missing_ok=True)
            if attempt:
                raise
        else:
            commit(part, destination)
            return destination, record


def tensor_header(path):
    from safetensors import safe_open

    # Validate the complete layout without materializing or touching tensor data.
    with safe_open(path, framework="pt", device="cpu"):
        pass
    with path.open("rb") as stream:
        length = struct.unpack("<Q", stream.read(8))[0]
        if length > 16 * 1024 * 1024:
            raise ValueError(f"Unreasonable safetensors header: {path}")
        return json.loads(stream.read(length)), 8 + length


def quantize_embedding(source, destination):
    import torch
    from compressed_tensors.compressors.pack_quantized.base import pack_to_int32

    torch.set_num_threads(min(4, os.cpu_count() or 1))
    header, source_start = tensor_header(source)
    keys = [key for key in header if key.endswith("embed_tokens.weight")]
    if len(keys) != 1:
        raise ValueError("Expected exactly one original embedding")
    key = keys[0]
    original = header[key]
    rows, columns = original["shape"]
    if original["dtype"] != "BF16" or columns % RECIPE["group_size"]:
        raise ValueError("Expected a BF16 group-128 embedding")
    prefix = key.removesuffix(".weight")
    packed_key, scale_key, shape_key = (prefix + suffix for suffix in (".weight_packed", ".weight_scale", ".weight_shape"))
    layout = {name: dict(value) for name, value in header.items() if name not in (key, "__metadata__")}
    layout.update({
        packed_key: {"dtype": "I32", "shape": [rows, columns // 4], "data_offsets": [0, rows * columns]},
        scale_key: {"dtype": "BF16", "shape": [rows, columns // 128], "data_offsets": [0, rows * (columns // 128) * 2]},
        shape_key: {"dtype": "I64", "shape": [2], "data_offsets": [0, 16]},
    })
    offset = 0
    for name in sorted(layout):
        entry = layout[name]
        size = entry["data_offsets"][1] - entry["data_offsets"][0]
        entry["data_offsets"] = [offset, offset + size]
        offset += size
    layout["__metadata__"] = header.get("__metadata__") or {"format": "pt"}
    encoded = json.dumps(layout, sort_keys=True, separators=(",", ":")).encode()
    encoded += b" " * (-len(encoded) % 8)
    data_start = 8 + len(encoded)
    part = destination.with_name(destination.name + ".part")
    part.unlink(missing_ok=True)
    squared_error = squared_weight = 0.0
    with source.open("rb", buffering=0) as src, part.open("w+b") as out:
        out.write(struct.pack("<Q", len(encoded)))
        out.write(encoded)
        out.truncate(data_start + offset)
        # Preserve all non-embedding tensors byte-for-byte, with bounded raw IO.
        for name, entry in header.items():
            if name in (key, "__metadata__"):
                continue
            begin, end = entry["data_offsets"]
            src.seek(source_start + begin)
            out.seek(data_start + layout[name]["data_offsets"][0])
            remaining = end - begin
            while remaining:
                chunk = src.read(min(IO_SIZE, remaining))
                if not chunk:
                    raise OSError("Truncated source tensor")
                out.write(chunk)
                remaining -= len(chunk)
        out.seek(data_start + layout[shape_key]["data_offsets"][0])
        out.write(struct.pack("<qq", rows, columns))
        src.seek(source_start + original["data_offsets"][0])
        for row in range(0, rows, BLOCK):
            count = min(BLOCK, rows - row)
            raw = bytearray(count * columns * 2)
            if src.readinto(raw) != len(raw):
                raise OSError("Truncated source embedding")
            w = torch.frombuffer(raw, dtype=torch.bfloat16).reshape(count, columns).float()
            groups = w.reshape(count, columns // 128, 128)
            scale = torch.clamp(groups.abs().amax(dim=-1, keepdim=True) / 127, min=1e-10)
            q = torch.clamp(torch.round(groups / scale), -128, 127).to(torch.int8).reshape(count, columns)
            packed = pack_to_int32(q, 8, packed_dim=1).contiguous()
            scales = scale.squeeze(-1).to(torch.bfloat16).contiguous()
            # Measure actual stored BF16 scales, a stricter check than upstream's
            # float32-scale diagnostic; quantized values remain identical.
            deq = (q.reshape_as(groups).float() * scales.float().unsqueeze(-1)).reshape_as(w)
            squared_error += (deq - w).square().sum(dtype=torch.float64).item()
            squared_weight += w.square().sum(dtype=torch.float64).item()
            for name, tensor, stride in ((packed_key, packed, columns), (scale_key, scales, columns // 128 * 2)):
                out.seek(data_start + layout[name]["data_offsets"][0] + row * stride)
                out.write(memoryview(tensor.view(torch.uint8).numpy()))
    error = math.sqrt(squared_error / squared_weight) if squared_weight else math.inf
    if not math.isfinite(error) or error >= 0.01:
        part.unlink()
        raise ValueError(f"Embedding relative error {error} exceeds 1%")
    tensor_header(part)
    record = digest_file(part)
    commit(part, destination)
    return record, error


def preparer_digest():
    return digest_file(Path(__file__))["sha256"]


def stamp(path):
    info = path.stat()
    return {"size": info.st_size, "mtime_ns": info.st_mtime_ns, "ctime_ns": info.st_ctime_ns, "inode": info.st_ino, "device": info.st_dev}


def inventory():
    return {
        ("drafter/" if family == "drafter" else "target/") + name: (family, name)
        for family, assets in ASSETS.items() for name in assets
    }


def verify_ready(root):
    """Check readiness without rereading 20 GB at each service start.

    Preparation hashes every asset; inode/device/mtime/size stamps bind that
    evidence to unchanged local files. The serving wrapper holds the model lock.
    """
    try:
        models = Path(root) / "models"
        manifest = json.loads((models / "manifest.json").read_text())
        if manifest["schema"] != 1 or manifest["preparer_sha256"] != preparer_digest():
            return False
        if set(manifest["sources"]) != set(PINS) or set(manifest["files"]) != set(inventory()):
            return False
        for family, (repo, revision) in PINS.items():
            source = manifest["sources"][family]
            if (source["repo"], source["revision"]) != (repo, revision) or set(source["files"]) != set(ASSETS[family]):
                return False
            for name, (size, digest) in ASSETS[family].items():
                entry = source["files"][name]
                if (entry["size"], entry["digest"]) != (size, digest):
                    return False
                if len(digest) == 64 and entry["sha256"] != digest:
                    return False
        embedding = manifest["embedding"]
        if embedding["recipe"] != RECIPE or embedding["preparer_sha256"] != preparer_digest():
            return False
        if embedding["source"] != {"size": ASSETS["base"][EMBED_SHARD][0], "sha256": ASSETS["base"][EMBED_SHARD][1]}:
            return False
        if not 0 <= embedding["relative_error"] < 0.01:
            return False
        for relative, (family, name) in inventory().items():
            record = manifest["files"][relative]
            if stamp(models / relative) != record["stat"] or record["size"] != record["stat"]["size"]:
                return False
            expected = embedding["output"] if name == EMBED_SHARD else manifest["sources"][family]["files"][name]
            if any(record[field] != expected[field] for field in ("size", "sha256")):
                return False
            if name.endswith((".json", ".jinja")):
                if digest_file(models / relative, ASSETS[family][name])["sha256"] != record["sha256"]:
                    return False
        return True
    except (OSError, ValueError, KeyError, TypeError):
        return False


def prepare(root):
    models = root / "models"
    models.mkdir(parents=True, exist_ok=True)
    with (models / ".prepare.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        (models / "manifest.json").unlink(missing_ok=True)
        sync_directory(models)
        target, drafter = models / "target", models / "drafter"
        target.mkdir(exist_ok=True)
        drafter.mkdir(exist_ok=True)
        manifest = {"schema": 1, "preparer_sha256": preparer_digest(), "sources": {}, "files": {}}
        source_paths = {}
        for family, (repo, revision) in PINS.items():
            source_manifest = {"repo": repo, "revision": revision, "files": {}}
            manifest["sources"][family] = source_manifest
            for name, (_, digest) in ASSETS[family].items():
                source, record = fetch(models, family, name)
                source_paths[family, name] = source
                source_manifest["files"][name] = dict(record, algorithm="git-sha1" if len(digest) == 40 else "sha256", digest=digest)
                if name == EMBED_SHARD:
                    continue
                destination = (drafter if family == "drafter" else target) / name
                part = destination.with_name(name + ".part")
                part.unlink(missing_ok=True)
                if destination.exists() and os.path.samefile(source, destination):
                    continue
                os.link(source, part)
                commit(part, destination)
        source = source_paths["base", EMBED_SHARD]
        destination = target / EMBED_SHARD
        receipt_path = models / "embedding.json"
        identity = {"recipe": RECIPE, "preparer_sha256": preparer_digest(), "source": manifest["sources"]["base"]["files"][EMBED_SHARD]}
        identity["source"] = {key: identity["source"][key] for key in ("size", "sha256")}
        receipt = None
        try:
            candidate = json.loads(receipt_path.read_text())
            if all(candidate.get(key) == value for key, value in identity.items()) and 0 <= candidate["relative_error"] < 0.01:
                if verified(destination, (candidate["output"]["size"], candidate["output"]["sha256"])):
                    receipt = candidate
        except (OSError, ValueError, KeyError, TypeError):
            pass
        if receipt is None:
            record, error = quantize_embedding(source, destination)
            receipt = dict(identity, output=record, relative_error=error)
            write_json(receipt_path, receipt)
        manifest["embedding"] = receipt
        # Verify the published index actually resolves every tensor in every shard.
        index = json.loads((target / "model.safetensors.index.json").read_text())["weight_map"]
        headers = {}
        for name in set(index.values()):
            if "target/" + name not in inventory():
                raise ValueError(f"Unpinned shard in index: {name}")
            headers[name] = tensor_header(target / name)[0]
        for key, name in index.items():
            if key not in headers[name]:
                raise ValueError(f"Missing indexed tensor: {key}")
        tensor_header(drafter / "model.safetensors")
        for relative, (family, name) in inventory().items():
            path = models / relative
            expected = (receipt["output"]["size"], receipt["output"]["sha256"]) if name == EMBED_SHARD else ASSETS[family][name]
            record = digest_file(path, expected)
            manifest["files"][relative] = dict(record, stat=stamp(path))
        write_json(models / "manifest.json", manifest)
        if not verify_ready(root):
            (models / "manifest.json").unlink(missing_ok=True)
            raise ValueError("Model readiness verification failed")
        print(f"Ready: {target} and {drafter}", flush=True)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: python prepare-model.py ROOT")
    prepare(Path(sys.argv[1]).resolve())
