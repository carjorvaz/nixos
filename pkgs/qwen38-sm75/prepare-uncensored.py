#!/usr/bin/env python3
"""Prepare the optional uncensored Qwen3.8 W4A16 checkpoint, or verify an existing one.

This is a second, independent model family beside the production target: it is
never downloaded by the default prepare path and never served unless its own
systemd unit is started. It downloads the pinned revision into
``ROOT/models/uncensored`` and verifies size and SHA-256 of every file and the
shard/index tensor coverage before publishing a readiness manifest.

Scope note: this is an alternative model, not a drop-in replacement. Measured
against the production target on the same prompt, its prefill is identical and
its per-step time is slightly better, but it decodes ~24% fewer tokens per second
- entirely because its abliterated MTP head accepts fewer drafts (2.7 vs ~4.2
tokens per step). Its own optimum is a shorter speculative chain (MTP3, measured
61.6 -> 64.0 tok/s over MTP4); the serving scripts pick that up via
flip-to-uncensored.sh. Head dtype is not the cause: this checkpoint ships int4
lm_head/embed with GPTQ-calibrated heads.
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
    "Marcin116/Qwen3.8-27B-Uncensored-W4A16-RTX3090-MTP4-embed-int4",
    "17e82c6ed1d308d06f1f7c2445cef6aa2a10d4cc",
)

# (size, sha256), hashed from the pinned revision's download. Lineage:
# Qwen/Qwen3.8-27B -> orcarouter/Qwen3.8-27B-Uncensored (abliterated, the
# independently verified one) -> noon-at-cgn/...-W4A16-AutoRound ->
# protogeni/...-RTX3090-MTP4 -> this repository (INT4 token embeddings; every
# other tensor byte-identical to the protogeni source). Built with
# syv-ai/qwen38-27b-rtx3090 for low-latency MTP speculative decoding, and it
# carries the mtp_draft_vocab_ids.pt plus MTP extras the serving config expects.
ASSETS = {
    "BUILD_INFO.md": (2436, "4e904aea42653899734d39593f035d5e1df6bff9134d306c275f6bc8fd96021c"),
    "chat_template.jinja": (8952, "c3cf9e34abf4f9e36c2d72165aa9c132d3e2a725b6c2586aaa3a8af9d7a81041"),
    "config.json": (22271, "ac3ccb54e6f53105cb0c8244d60bd55c5d97c9cbfac9592c282fc8c029f318c8"),
    "generation_config.json": (214, "477f11fe8f40945690a1df951acb82bfc75c68502aa10a02f436b25aea41b483"),
    "LICENSE": (11358, "cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30"),
    "model-00001-of-00007.safetensors": (3211003472, "098ab1bf1f19503295a0eccc94d341eab7d8eaf063701503d20b1bb283824c03"),
    "model-00002-of-00007.safetensors": (3195027104, "34f6f3248523d9bc3def2eeb89621882202753059f5cc5eda6d8fd69dfb0aae2"),
    "model-00003-of-00007.safetensors": (3195027104, "1b71bc623c85741c969dd70820c621cbaa9b4ba65e7c430c7bf37643e57c46c6"),
    "model-00004-of-00007.safetensors": (3217442568, "ad40637ca14ff3f1d33fe966b82cdc1bd8ab91fb2239cc981f3cfbd1bc1301a7"),
    "model-00005-of-00007.safetensors": (699275200, "0994bb8d91c07ceefc4bfffd3a7b7fd110cc9bd3ce865bdcb2821abf02a02fab"),
    "model-00006-of-00007.safetensors": (655575539, "c62d3ad3045ff222ab60e00b57f23ac30ebf9211da941db4d90f2279dfd7a915"),
    "model-00007-of-00007.safetensors": (655565120, "7ac881a6dfc9d75e7211c370febfe835fab42dbecdc7c48f551cccc171284acb"),
    "model_extra_tensors.safetensors": (327162544, "ebc7f6ef31723081c64bc5dfe9a7b76b8ceb4e969f6b977d732ec9f8451ace12"),
    "model.safetensors.index.json": (200182, "9ad95c7931a6b87eda720477691f7487744740e0bfefed5c794c6ab1331b395f"),
    "mtp_draft_vocab_ids.pt": (329341, "258abe858bed3b676368da9d330f2c33c32a4b34d3a0fb56918f4bcd276b3509"),
    "processor_config.json": (1191, "d89ef49ce9cd37fbf510158e13c1ef063d9286411c1ec9049932dbe0487143b1"),
    "quantization_config.json": (16136, "394dacad1bd8e205d420dbc55ac3d87b4fe98b114479e8b34f2c9b90f3c922f3"),
    "README.md": (14262, "ed15c2ef7a32cd7345a62218d367a99dd821b458dcc98127209effaa80cececf"),
    "tokenizer_config.json": (1165, "792fa3f0cb88b111e54ef3134c873531008c4df471d108da17903426e308aa7b"),
    "tokenizer.json": (19989325, "06b9509352d2af50381ab2247e083b80d32d5c0aba91c272ca9ff729b6a0e523"),
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
