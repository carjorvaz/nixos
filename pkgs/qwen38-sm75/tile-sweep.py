#!/usr/bin/env python3
"""Make the prefill tile port's constants tunable, for a sweep.

The prefill tile port (carjorvaz/qwen38-27b-rtx2080ti `patches-turing/prefill-attn-tiles.patch`)
rewrites PyTorch's attention header at load time; its warp-N tile and its
minimum blocks per SM were fixed choices. This script reads both from the environment, writes them into the
header, and names the JIT build directory after them -- a header change alone
does not invalidate torch's extension cache.

Defaults reproduce the shipped constants exactly, so the runtime is unchanged
unless the environment says otherwise. Applied to a prepared runtime's copy:

    tile-sweep.py /persist/qwen38-sm75/venv/lib/python3.12/site-packages/\\
        vllm/v1/attention/ops/turing_prefill_tiles.py

Then sweep with the same interpreter (each new pair rebuilds the extension,
about two minutes):

    VLLM_TURING_PREFILL_WARPN=64 VLLM_TURING_PREFILL_MINBLOCKS=2 \\
        python prefill-bench.py --lengths 65536,262144 --chunks 2048

Measured 2026-09-19 on the 64k/256k shapes: warpN=64/minBlocks=1 (shipped)
103.7 and 410.8 ms; minBlocks=2 gives 100.6 and 410.5; warpN=128 gives 544.9
and 2204.5 (register spills break the load iterator); warpN=32 does not
compile. The shipped constants are the right ones -- at 32 TFLOPS effective the
kernel is at 60-70% of the sm75 fp32-accumulate ceiling, so the remaining gap
is the Cutlass template's shape, not a tunable. Recorded in
`docs/VALIDATION.md`; the patch that ships in the runtime keeps 64 and 1.
"""

import pathlib
import sys

path = pathlib.Path(sys.argv[1])
s = path.read_text()

if "_TILE_WARPN" in s:
    print("already installed")
    sys.exit(0)

reps = [
    (
        """@cache
def load_turing_prefill_tiles():
    from torch.utils.cpp_extension import get_default_build_root, load
    import vllm

    name = "qwen38_turing_prefill_tiles"
    build = Path(os.environ.get("TORCH_EXTENSIONS_DIR", get_default_build_root())) / name""",
        """_TILE_WARPN = int(os.environ.get("VLLM_TURING_PREFILL_WARPN", "64") or 64)
_TILE_MINBLOCKS = int(os.environ.get("VLLM_TURING_PREFILL_MINBLOCKS", "1") or 1)


@cache
def load_turing_prefill_tiles():
    from torch.utils.cpp_extension import get_default_build_root, load
    import vllm

    name = f"qwen38_turing_prefill_tiles_w{_TILE_WARPN}_m{_TILE_MINBLOCKS}"
    build = Path(os.environ.get("TORCH_EXTENSIONS_DIR", get_default_build_root())) / name""",
    ),
    (
        """         "  // Wider N warp tiles preserve the small query operand's load iterator.\\n"
         "  static constexpr int kWarpN = kKeysPerBlock == 256 ? 64 : 32;\\n\"""",
        """         "  // Wider N warp tiles preserve the small query operand's load iterator.\\n"
         f"  static constexpr int kWarpN = kKeysPerBlock == 256 ? {_TILE_WARPN} : 32;\\n\"""",
    ),
    (
        """        ("  static constexpr int kMinBlocksPerSm =\\n",
         "  static constexpr int kMinBlocksPerSm = kKeysPerBlock == 256 ? 1 :\\n", 1),""",
        """        ("  static constexpr int kMinBlocksPerSm =\\n",
         f"  static constexpr int kMinBlocksPerSm = kKeysPerBlock == 256 ? {_TILE_MINBLOCKS} :\\n", 1),""",
    ),
]
for old, new in reps:
    if s.count(old) != 1:
        sys.exit(f"anchor count {s.count(old)}: {old[:70]!r}")
    s = s.replace(old, new)
path.write_text(s)
print("tile constants tunable")
