#!/usr/bin/env python3
"""Prepare the optional uncensored Qwen3.8 W4A16 checkpoint, or verify an existing one.

This is a second, independent model family beside the production target: it is
never downloaded by the default prepare path and never served unless its own
systemd unit is started. It downloads the pinned revision into
``ROOT/models/uncensored`` and verifies size and SHA-256 of every file and the
shard/index tensor coverage before publishing a readiness manifest.

Scope note: the uncensored checkpoint ships an int8 lm_head/embed and a bf16
MTP head, so it is slower than the calibrated int4 fast variant (measured
~30% lower decode with MTP4). It is an alternative model, not a drop-in
replacement; requantizing its lm_head/MTP against its own weights is the only
way to close that gap.
"""

import fcntl
import importlib.util
import json
import os
import sys
from pathlib import Path


_spec = importlib.util.spec_from_file_location(
    "prepare_model", Path(__file__).resolve().parent / "prepare-model.py"
)
helper = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = helper
_spec.loader.exec_module(helper)


PIN = (
    "leminkozey/Qwen3.8-27B-Uncensored-W4A16-AutoRound",
    "f958acb153eb8c7bbd25638149c8c75185559226",
)

# (size, sha256), hashed from the pinned revision's download. The repository
# also carries *.bak files; they are intentionally not part of the model.
ASSETS = {
    "chat_template.jinja": (8952, "c3cf9e34abf4f9e36c2d72165aa9c132d3e2a725b6c2586aaa3a8af9d7a81041"),
    "config.json": (16746, "48f115f0c4641c58426e55b49d20d9ae220d386949bc61cd175e5581f5ba1dfb"),
    "generation_config.json": (214, "6ef70d6670f24f03a9041724c7663ef26bc1e678d10f79c93fe11c192ba14b7d"),
    "model-00001-of-00007.safetensors": (3211003472, "1db7aff443812f7bd11869336c0b75a6ec59e70f089bf65208598a6bbe7a5eb3"),
    "model-00002-of-00007.safetensors": (3195027104, "4b0c689af764d1fd35dd271ab95f7aa20bf305197fd98e68ad69a7367b199b13"),
    "model-00003-of-00007.safetensors": (3195027104, "75da50f643fb84a21cefe5a5186b3db35e6a941f21401e650e684eb7f3d34d1d"),
    "model-00004-of-00007.safetensors": (3217442568, "487171bff5e5361f3e6dba6b5da765b17e78a154823b5145dab616ec37cac67c"),
    "model-00005-of-00007.safetensors": (699275200, "0994bb8d91c07ceefc4bfffd3a7b7fd110cc9bd3ce865bdcb2821abf02a02fab"),
    "model-00006-of-00007.safetensors": (1291274752, "b2e0854ed3be3141ed79f4204f7aa8e616da626d4662017117330490747c2036"),
    "model-00007-of-00007.safetensors": (1291264320, "ce55d80ec123bac872f2ff27eb39b2c11d50ede0b0e272656738b628b7f496a9"),
    "model.safetensors.index.json": (198612, "d96e1d1a01dd2ad852fd34bd7624917a96731aa4d15f48c4aaba5217b6525552"),
    "model_extra_tensors.safetensors": (849400392, "1d8268aa85ace093a561e3e7b63b9d390dac1cd55a90cd55b5ec509c3c9da9fe"),
    "processor_config.json": (1220, "bfbc24af59a3e73a9cd0653b8d4ae758dfaec4e3e6c15dfb1c6c8ee8d5683c85"),
    "quantization_config.json": (11374, "804a69418fb6070b312327f778952739a9c742c13aa2e3eaa0042bdaefe43c78"),
    "tokenizer.json": (19989325, "06b9509352d2af50381ab2247e083b80d32d5c0aba91c272ca9ff729b6a0e523"),
    "tokenizer_config.json": (1165, "792fa3f0cb88b111e54ef3134c873531008c4df471d108da17903426e308aa7b"),
}

SCHEMA = 1


def asset_dir(root):
    return Path(root) / "models" / "uncensored"


def manifest_path(root):
    return Path(root) / "models" / "uncensored-manifest.json"


def preparer_digest():
    return helper.digest_file(Path(__file__))["sha256"]


def prepare(root):
    models = Path(root) / "models"
    models.mkdir(parents=True, exist_ok=True)
    destination_dir = asset_dir(root)
    destination_dir.mkdir(parents=True, exist_ok=True)
    with (models / ".uncensored.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        manifest_file = manifest_path(root)
        manifest_file.unlink(missing_ok=True)
        helper.sync_directory(models)
        helper.PINS = {"uncensored": PIN}
        helper.ASSETS = {"uncensored": ASSETS}
        manifest = {"schema": SCHEMA, "preparer_sha256": preparer_digest(), "source": {"repo": PIN[0], "revision": PIN[1], "files": {}}, "files": {}}
        for name, (size, digest) in ASSETS.items():
            source, record = helper.fetch(models, "uncensored", name)
            manifest["source"]["files"][name] = dict(record, algorithm="sha256", digest=digest)
            destination = destination_dir / name
            part = destination.with_name(name + ".part")
            part.unlink(missing_ok=True)
            if destination.exists() and os.path.samefile(source, destination):
                continue
            os.link(source, part)
            helper.commit(part, destination)
        # Every tensor the published index names must exist in the shard it
        # names, and the extras file must be a valid safetensors container.
        index = json.loads((destination_dir / "model.safetensors.index.json").read_text())["weight_map"]
        headers = {}
        for shard in set(index.values()):
            if shard not in ASSETS:
                raise ValueError(f"Unpinned shard in index: {shard}")
            headers[shard] = helper.tensor_header(destination_dir / shard)[0]
        for key, shard in index.items():
            if key not in headers[shard]:
                raise ValueError(f"Missing indexed tensor: {key}")
        helper.tensor_header(destination_dir / "model_extra_tensors.safetensors")
        for name in ASSETS:
            path = destination_dir / name
            manifest["files"][name] = dict(helper.digest_file(path, ASSETS[name]), stat=helper.stamp(path))
        helper.write_json(manifest_file, manifest)
        if not verify_ready(root):
            manifest_file.unlink(missing_ok=True)
            raise ValueError("Uncensored model readiness verification failed")
        print(f"Ready: {destination_dir}", flush=True)


def verify_ready(root):
    """Cheap readiness check: manifest identity, file stamps, small-file hashes."""
    try:
        manifest = json.loads(manifest_path(root).read_text())
        if manifest["schema"] != SCHEMA or manifest["preparer_sha256"] != preparer_digest():
            return False
        if (manifest["source"]["repo"], manifest["source"]["revision"]) != PIN:
            return False
        if set(manifest["files"]) != set(ASSETS) or set(manifest["source"]["files"]) != set(ASSETS):
            return False
        for name, (size, digest) in ASSETS.items():
            entry = manifest["source"]["files"][name]
            if (entry["size"], entry["digest"]) != (size, digest):
                return False
            path = asset_dir(root) / name
            record = manifest["files"][name]
            if helper.stamp(path) != record["stat"] or record["size"] != size:
                return False
            if name.endswith((".json", ".jinja")):
                if helper.digest_file(path, ASSETS[name])["sha256"] != record["sha256"]:
                    return False
        return True
    except (OSError, ValueError, KeyError, TypeError):
        return False


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: python prepare-uncensored.py ROOT")
    root = Path(sys.argv[1]).resolve()
    if verify_ready(root):
        print(f"Already ready: {asset_dir(root)}", flush=True)
    else:
        prepare(root)
