# NInfer SM75 packaging and corrections

The package pins `mr-september/ninfer-2080ti-22g` and builds natively with CUDA's
supported host compiler. This is SM75-specific, not a portable CUDA binary.
The model artifact and service lifecycle belong to
`profiles/nixos/ninfer-qwen.nix`; see [runtime validation](../../docs/VALIDATION.md).

## Patches

### INT8 correctness

`turing-int8-correctness.patch` fixes two independent classes of Turing bugs:

- The `m16n8k32` INT8 and `m16n8k16` FP16 A fragments are ordered
  `[M0K0, M1K0, M0K1, M1K1]`. The fork's decompositions confused registers
  `a1` and `a2`, mixing matrix rows with reduction-dimension halves. INT8
  decode/prefill uses the INT8 helper; INT8 prefill also uses the FP16 helper.
- SM75 prefill tiles contain 32 keys but a cache page contains 64. Both code
  and scale loads must include the offset of the tile within the page.
  Using only `key_l` rereads positions 0–31 for keys 32–63, and so on.
  The 64-key tiles on other architectures masked this mistake.

The register contracts are documented in NVIDIA's PTX ISA:
[m16n8k32](https://docs.nvidia.com/cuda/parallel-thread-execution/index.html#warp-level-matrix-fragment-mma-16832),
[m8n8k16](https://docs.nvidia.com/cuda/parallel-thread-execution/index.html#warp-level-matrix-fragment-mma-8816),
[m16n8k16 floating point](https://docs.nvidia.com/cuda/parallel-thread-execution/index.html#warp-level-matrix-fragment-mma-16816-float),
and [m16n8k8](https://docs.nvidia.com/cuda/parallel-thread-execution/index.html#warp-level-matrix-fragment-mma-1688).

### BF16 range and deterministic padding

SM75 retains the original **inlined BF16 SIMT implementation**, including FP32
accumulation and BF16's full exponent range. Do not narrow BF16 to FP16 merely
because the device has FP16 Tensor Cores. A guarded FP16/outlined-SIMT experiment
passed numerical checks but regressed an identical serving benchmark; primitive
microbenchmarks were not sufficient evidence to ship it.

`turing-initialized-mma-padding.patch` explicitly zeros unused SM75 activation
columns in affected W8, Q4 and FP8 kernels. Although those columns should not
influence live SIMT outputs, keep them deterministic across schedules rather than
relying on stale shared memory. Other architectures retain their staging policies.
Exact recurrent-state comparisons and numerical tolerances remain unchanged.

### Narrow W8 vocabulary and fused Q5 residual routes

`turing-w8-vocab-simt.patch` selects the existing four-column SIMT implementation
only for the SM75 vocabulary geometry N=248320, K=5120, T=1–4. Other geometries
and widths retain their selectors. No activation casts or workspace are added.

`turing-q5-residual-slices.patch` targets **fused `linear_add`**, not plain Q5
`linear`: N=5120, K=6144 or 17408, T=129–1024. It explicitly partitions columns
into slices of four, using the existing exact residual kernels and a GEMV tail
for one column. The grid.y-limit slicing helper does not bound slices to four;
using it recursively for this purpose would reselect the same route indefinitely.

Both retain BF16's exponent range. The complete `linear_add` contract permits
private intermediate-rounding differences; retain its original FP64 ideal
projection-plus-residual oracle and original tolerances, not a route-specific
reference or weakened bound. Range/guard/graph checks and real serving prefill
must qualify a selector change. A faster plain Q5 microbenchmark did not improve
serving prefill because the hot fused residual path bypasses that dispatcher.
Neither kernel improvement establishes general coding quality or fixes empty
model replies; API and near-limit lifecycle qualification remain separate.

### FP8 activation fallback

`turing-fp8-a16-fallback.patch` prevents `AllowA8` from selecting an unsupported
FP8 MMA on SM75/SM86. The policy permits lower-precision activations; it does not
require them. FP8 weights remain supported through A16 computation. All linear,
projection, residual, SwiGLU and GDN convolution planners use the capability,
including independent interval/workspace queries. Shape and policy validation
remain in place. An accidental unsupported intrinsic call now traps rather than
silently returning zero products.

The pinned `mma.cuh` has CRLF line endings. `prePatch` normalizes only that file
so the checked-in patches remain ordinary LF text.

## Opt-in GPU regressions

Builds require Linux/CUDA tooling, **not** an attached GPU. Execution requires a
real SM75 device and a maintenance window. These are not automatic Nix checks,
and must not be run by public CI or against an occupied production GPU.

```sh
nix build --no-link .#packages.x86_64-linux.ninfer-sm75.mmaCheck
nix build --no-link .#packages.x86_64-linux.ninfer-sm75.paddingCheck
nix build --no-link .#packages.x86_64-linux.ninfer-sm75.gpuTests
```

- `mmaCheck/bin/ninfer-sm75-check-mma` is independently buildable. It packs
  documented register layouts, compares INT8/FP16/BF16 products with CPU dense
  references, changes inputs across fixed-address CUDA graph replays, exercises
  mixed exponents and single-lane range stress. All BF16 product fixtures remain
  enabled, including tiny values, cancellation and wide exponents. The unpatched fork
  should fail its INT8/FP16 cases; do not accept a test that merely runs.
- `paddingCheck/bin/ninfer-sm75-check-padding` independently checks W8 live outputs
  against an explicit zero-padding schedule at widths 1–6. It poisons shared
  memory with finite/non-finite patterns and requires exact, finite results after
  poisoning output, so stale or unwritten results cannot pass.
- `gpuTests/bin/ninfer_gqa_attention_test` uses the production library and the
  upstream CPU oracle/tolerances. The regression patch adds half-page boundaries,
  fragmented storage, partial tiles, speculative widths 1–6, and eager/graph
  execution with poisoned output. Existing tests also check quantized writes,
  guards, masked batches, unchanged inputs and workspace accounting.
- The other `gpuTests/bin/*_test` programs cover Q4/Q5/Q6/W8/BF16/FP8 linear
  operations, Q5/FP8 residual and FP8 SwiGLU operations, input projections, GDN
  convolution snapshots/records, Gated DeltaNet and replay folding/recording. The BF16 helper
  is shared by more than attention, so validation must not stop at a primitive.

`gpuTests/bin/ninfer_linear_add_q5_a16_test` uses the original complete-Op oracle
and covers both residual geometries, selector transitions and their neighbors,
and wider prefill points through 1026 tokens. In particular, 128/129 and 1024/1025
must not silently change admission, workspace, or numerical criteria.

`test-projection-architecture.patch` skips only unsupported NVFP4 projection
cases and their workspace queries on SM75/SM86. `test-fp8-capabilities.patch`
requires A16-equivalent workspace capacity when `AllowA8` falls back, while
retaining native-A8 witnesses on Blackwell. Neither drops FP8 numerical cases nor
loosens their tolerances.

`gpuTests` is a separate derivation linked to the production build's internal
`dev` archives, so test-only edits do not recompile CUDA or enter the service
closure. Tests also receive the production header patches. A shared dispatcher
avoids duplicating the large archive in every test; wrappers preserve the upstream
executable names and separate processes. Keep test output and maintenance scripts
outside this public repository. Kernel tests do not replace API exact-answer,
near-limit retrieval, cached-continuation, prefix-replacement and zero-cache
full recomputation checks under service limits.
