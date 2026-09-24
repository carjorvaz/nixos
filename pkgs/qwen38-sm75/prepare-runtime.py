#!/usr/bin/env python3
"""Prepare a pinned, separately staged runtime, or serve an already ready one.

The patch stack is the pinned source's: `patches/` (upstream's 3090 series)
followed by `patches-turing/` in `series` order (the Turing port). The assets
directory carries only the model preparation, checks and benchmarks that run
against the prepared runtime.
"""

import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import uuid


REVISION = os.environ.get("QWEN_SOURCE_REVISION", "")
if not REVISION:
    raise RuntimeError(
        "QWEN_SOURCE_REVISION is unset; run this through the packaged wrappers"
    )
VLLM_VERSION = "0.29.0"
IDENTITY_ENV = (
    "PATH", "CC", "CXX", "CUDAHOSTCXX", "NVCC_CCBIN", "CUDA_HOME",
    "LD_LIBRARY_PATH", "TRITON_LIBCUDA_PATH", "TRITON_PTXAS_PATH",
)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_series(path):
    """Names from a series file: one basename per line, `#` comments ignored."""
    names = []
    for line in path.read_text().splitlines():
        name = line.split("#", 1)[0].strip()
        if name:
            names.append(name)
    return names


def series_patches(directory, skip=()):
    """The patches a series file names, in order, minus `skip`.

    The series file is the apply order (upstream's Dockerfile and checker use
    it); a glob is not. It and the directory must agree exactly.
    """
    names = read_series(directory / "series")
    files = sorted(path.name for path in directory.glob("*.patch"))
    if not names or sorted(names) != files:
        raise RuntimeError(f"{directory}/series does not match {directory}/*.patch")
    patches = []
    for name in names:
        if name in skip:
            continue
        path = directory / name
        if not path.is_file():
            raise RuntimeError(f"{directory}/series names a missing patch: {name}")
        patches.append(path)
    return patches


def specification(source, assets, python):
    upstream = series_patches(source / "patches", skip=("dflash2-backport.patch",))
    turing = series_patches(source / "patches-turing")
    if len(upstream) != 44 or not turing:
        raise RuntimeError(
            "Expected the pinned source to carry the 44-patch 3090 series and the Turing port"
        )
    identity = {
        "schema": 1,
        "revision": REVISION,
        "python": str(python.resolve(strict=True)),
        "native": {name: os.environ[name] for name in IDENTITY_ENV},
        "requirements": digest(assets / "requirements.lock"),
        "preparer": digest(Path(__file__)),
        "patches": {
            **{f"upstream/{p.name}": digest(p) for p in upstream},
            **{f"turing/{p.name}": digest(p) for p in turing},
        },
    }
    fingerprint = hashlib.sha256(
        json.dumps(identity, sort_keys=True).encode()
    ).hexdigest()
    return identity, fingerprint, upstream + turing


def runtime_ready(root, identity, fingerprint):
    try:
        manifest = json.loads((root / "runtime-manifest.json").read_text())
        runtime = (root / "venv").resolve(strict=True)
        return (
            manifest["identity"] == identity
            and manifest["fingerprint"] == fingerprint
            and manifest["runtime"] == str(runtime)
            and runtime.parent == root / "runtimes"
            and (runtime / "bin/python").is_file()
            and (runtime / "bin/vllm").is_file()
            and (runtime / "pyvenv.cfg").is_file()
            and (runtime / "bin/python").resolve() == Path(identity["python"])
        )
    except (OSError, ValueError, KeyError, TypeError):
        return False


def prepare(root, assets, python, identity, fingerprint, patches):
    if runtime_ready(root, identity, fingerprint):
        print("qwen38-sm75: runtime already ready", flush=True)
        return

    # A failure leaves the old runtime and every model/cache untouched, but no
    # readiness claim. New generations have permanent paths: venv shebangs must
    # not point at a staging directory that will subsequently be renamed.
    marker = root / "runtime-manifest.json"
    marker.unlink(missing_ok=True)
    generations = root / "runtimes"
    generations.mkdir(exist_ok=True)
    runtime = generations / f"{fingerprint[:16]}-{uuid.uuid4().hex}"
    subprocess.run([str(python), "-m", "venv", str(runtime)], check=True)
    executable = str(runtime / "bin/python")
    # The complete lock comes from the validated runtime. Do not let a resolver
    # replace those versions, and do not compile an sdist on a low-RAM host.
    # A fresh venv also restores the pristine wheel even if ROOT/venv was patched
    # by hand or a previous attempt failed halfway through the patch series.
    subprocess.run([
        executable, "-m", "pip", "--isolated", "install",
        "--index-url", "https://pypi.org/simple", "--only-binary=:all:",
        "--no-deps", "--disable-pip-version-check",
        "--cache-dir", str(root / "cache/pip"),
        "-r", str(assets / "requirements.lock"),
    ], check=True)
    package = Path(subprocess.check_output([
        executable, "-c",
        "import importlib.metadata as m; "
        f"assert m.version('vllm') == {VLLM_VERSION!r}; "
        "print(m.distribution('vllm').locate_file('vllm'))",
    ], text=True).strip())
    if not package.is_relative_to(runtime):
        raise RuntimeError("vLLM installation escaped the new runtime")
    for patch in patches:
        print(f"qwen38-sm75: applying {patch.name}", flush=True)
        subprocess.run([
            "patch", "--batch", "--forward", "--no-backup-if-mismatch",
            "--fuzz", "0",
            "-p1", "-d", str(package), "-i", str(patch),
        ], check=True)

    current = root / "venv"
    link = root / f".venv-{uuid.uuid4().hex}"
    link.symlink_to(runtime)
    if current.exists() and not current.is_symlink():
        # Preserve the original hand-built venv, rather than deleting it.
        current.rename(generations / f"legacy-{uuid.uuid4().hex}")
    os.replace(link, current)
    manifest = {
        "identity": identity,
        "fingerprint": fingerprint,
        "runtime": str(runtime),
    }
    temporary = root / f".runtime-manifest-{uuid.uuid4().hex}.json"
    with temporary.open("x") as output:
        json.dump(manifest, output, sort_keys=True)
        output.write("\n")
        output.flush()
        os.fsync(output.fileno())
    os.replace(temporary, marker)
    print("qwen38-sm75: runtime ready", flush=True)


def serve(root, assets, identity, fingerprint, arguments):
    if not runtime_ready(root, identity, fingerprint):
        raise RuntimeError("Runtime is missing or stale; run qwen38-sm75-prepare first")
    # Experiment hook: extra vLLM arguments for A/B runs, split on shell rules.
    # The validated service never sets this; set it only on a scrapped or
    # explicitly restored server, and put the result in a new fingerprint
    # (a patch or a host-config change) before trusting it.
    extra = os.environ.get("QWEN_EXTRA_ARGS", "").strip()
    if extra:
        parsed = shlex.split(extra)
        print(f"qwen38-sm75: appending QWEN_EXTRA_ARGS={parsed!r}", flush=True)
        arguments = [*arguments, *parsed]
    # Safe mode for stability bisects: drop the speculative-decoding flag and
    # its value so the engine runs the target without a draft model.
    if os.environ.get("QWEN_DISABLE_SPEC", "0") == "1":
        filtered, skip = [], False
        for argument in arguments:
            if skip:
                skip = False
                continue
            if argument == "--speculative-config":
                skip = True
                continue
            filtered.append(argument)
        print("qwen38-sm75: QWEN_DISABLE_SPEC=1; speculative config removed", flush=True)
        arguments = filtered
    # Hold the model lock too: standalone preparation must not modify files in
    # use by this server. File descriptors remain open through exec.
    with (root / "models/.prepare.lock").open("a+") as model_lock:
        fcntl.flock(model_lock, fcntl.LOCK_SH | fcntl.LOCK_NB)
        spec = importlib.util.spec_from_file_location(
            "qwen38_prepare_model", assets / "prepare-model.py"
        )
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        if not module.verify_ready(root):
            raise RuntimeError("Models are missing or stale; run qwen38-sm75-prepare first")
        os.set_inheritable(model_lock.fileno(), True)
        os.environ["HF_HUB_OFFLINE"] = "1"
        os.environ["TRANSFORMERS_OFFLINE"] = "1"
        executable = str(root / "venv/bin/vllm")
        os.execv(executable, [executable, "serve", *arguments])


def main():
    if len(sys.argv) < 5 or (len(sys.argv) > 5 and sys.argv[5] != "--serve"):
        raise RuntimeError(
            "Usage: prepare-runtime.py ROOT UPSTREAM_SOURCE ASSET_DIR PYTHON_EXECUTABLE "
            "[--serve VLLM_ARGS...]"
        )
    root, source, assets, python = (Path(arg).absolute() for arg in sys.argv[1:5])
    serving = len(sys.argv) > 5
    if not serving:
        root.mkdir(parents=True, exist_ok=True)
    root = root.resolve(strict=True)
    identity, fingerprint, patches = specification(source, assets, python)
    with (root / ".runtime.lock").open("a+") as lock:
        mode = fcntl.LOCK_SH if serving else fcntl.LOCK_EX
        fcntl.flock(lock, mode | fcntl.LOCK_NB)
        if serving:
            os.set_inheritable(lock.fileno(), True)
            serve(root, assets, identity, fingerprint, sys.argv[6:])
        else:
            prepare(root, assets, python, identity, fingerprint, patches)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.CalledProcessError) as error:
        sys.exit(f"qwen38-sm75: {error}")
