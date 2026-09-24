// Opt-in, model-free SM75 regression. Exercise the actual patched helpers,
// independently packing NVIDIA's documented register layouts and comparing
// against a CPU dense product. No GPU is needed to build this executable.
// PTX ISA: warp-level-matrix-fragment-mma-{16832,8816,16816-float,1688}.
#include "ops/common/mma.cuh"

#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cuda_runtime.h>
#include <iostream>
#include <random>
#include <vector>

static void check(cudaError_t result) {
    if (result != cudaSuccess) {
        std::cerr << cudaGetErrorString(result) << '\n';
        std::exit(2);
    }
}

// Kind 0: INT8; 1: FP16; 2: BF16. Input values are on their dtype's grid.
template <int Kind> __device__ unsigned pack(const float *matrix, int stride, int offset) {
    unsigned result = 0;
    constexpr int count = Kind == 0 ? 4 : 2;
    for (int i = 0; i < count; ++i) {
        const float value = matrix[offset + i * stride];
        unsigned bits;
        if constexpr (Kind == 0) {
            bits = static_cast<unsigned char>(static_cast<signed char>(value));
        } else if constexpr (Kind == 1) {
            bits = __half_as_ushort(__float2half_rn(value));
        } else {
            bits = __bfloat16_as_ushort(__float2bfloat16_rn(value));
        }
        result |= bits << (i * (Kind == 0 ? 8 : 16));
    }
    return result;
}

template <int Kind>
__global__ void product(const float *a, const float *b, const float *c, float *out) {
    constexpr int elements = Kind == 0 ? 4 : 2;
    constexpr int k_half = 4 * elements;
    constexpr int k = 2 * k_half;
    const int group = threadIdx.x / 4, thread = threadIdx.x % 4;
    unsigned ar[4], br[2];
    // A register order: M0K0, M1K0, M0K1, M1K1.
    for (int reg = 0; reg < 4; ++reg) {
        ar[reg] =
            pack<Kind>(a, 1, (group + 8 * (reg % 2)) * k + thread * elements + k_half * (reg / 2));
    }
    for (int reg = 0; reg < 2; ++reg) {
        br[reg] = pack<Kind>(b, 8, (thread * elements + k_half * reg) * 8 + group);
    }
    float accum[4];
    for (int i = 0; i < 4; ++i) {
        accum[i] = c[(group + 8 * (i / 2)) * 8 + 2 * thread + i % 2];
    }
    if constexpr (Kind == 0) {
        int ci[4];
        for (int i = 0; i < 4; ++i)
            ci[i] = static_cast<int>(accum[i]);
        ninfer::ops::mma_s8(ci[0], ci[1], ci[2], ci[3], ar[0], ar[1], ar[2], ar[3], br[0], br[1]);
        for (int i = 0; i < 4; ++i)
            accum[i] = static_cast<float>(ci[i]);
    } else if constexpr (Kind == 1) {
        ninfer::ops::mma_f16(accum[0], accum[1], accum[2], accum[3], ar[0], ar[1], ar[2], ar[3],
                             br[0], br[1]);
    } else {
        ninfer::ops::mma_bf16(accum[0], accum[1], accum[2], accum[3], ar[0], ar[1], ar[2], ar[3],
                              br[0], br[1]);
    }
    for (int i = 0; i < 4; ++i) {
        out[(group + 8 * (i / 2)) * 8 + 2 * thread + i % 2] = accum[i];
    }
}

// Optional diagnostic for experimental guarded implementations. The production
// BF16 path is the original SIMT implementation and does not narrow to FP16.
#ifdef NINFER_CHECK_EXACT_GUARD
__global__ void check_conversion_guard(int *failures) {
    const unsigned bits = blockIdx.x * blockDim.x + threadIdx.x;
    const float value = __uint_as_float(bits << 16);
    const unsigned roundtrip = __float_as_uint(__half2float(__float2half_rn(value)));
    const bool finite = (bits & 0x7f80u) != 0x7f80u;
    // Compare bits, not tiny floating operands that fast-math could flush.
    const bool exact = finite && roundtrip == (bits << 16);
    if (ninfer::ops::bf16_fits_f16(bits) != exact)
        atomicAdd(failures, 1);
}
#endif

template <int Kind> int run() {
    constexpr int k = Kind == 0 ? 32 : 16;
    constexpr const char *name = Kind == 0 ? "INT8" : Kind == 1 ? "FP16" : "BF16";
    std::vector<float> a(16 * k), b(k * 8), c(128), actual(128);
    float *da, *db, *dc, *dout;
    check(cudaMalloc(&da, a.size() * sizeof(float)));
    check(cudaMalloc(&db, b.size() * sizeof(float)));
    check(cudaMalloc(&dc, 128 * sizeof(float)));
    check(cudaMalloc(&dout, 128 * sizeof(float)));
    check(cudaMemset(da, 0, a.size() * sizeof(float)));
    check(cudaMemset(db, 0, b.size() * sizeof(float)));
    check(cudaMemset(dc, 0, 128 * sizeof(float)));
    cudaStream_t stream;
    check(cudaStreamCreate(&stream));
    // Warm up before capture, then replay with changed inputs at fixed addresses.
    product<Kind><<<1, 32, 0, stream>>>(da, db, dc, dout);
    check(cudaStreamSynchronize(stream));
    cudaGraph_t graph;
    cudaGraphExec_t executable;
    check(cudaStreamBeginCapture(stream, cudaStreamCaptureModeGlobal));
    product<Kind><<<1, 32, 0, stream>>>(da, db, dc, dout);
    check(cudaStreamEndCapture(stream, &graph));
    check(cudaGraphInstantiate(&executable, graph, nullptr, nullptr, 0));
    int failures = 0;
    std::mt19937 random(20260902);
    const int fixtures = Kind == 2 ? 104 : 20;
    for (int fixture = 0; fixture < fixtures; ++fixture) {
        auto fill = [&](std::vector<float> &values) {
            for (float &value : values) {
                const int sample = static_cast<int>(random() % 256) - 128;
                value = Kind == 0 ? static_cast<float>(sample) : sample / 128.0f;
            }
        };
        fill(a);
        fill(b);
        fill(c);
        if constexpr (Kind == 2) {
            if (fixture >= 20 && fixture < 40) {
                for (float &value : a)
                    value = std::ldexp(value, 20);
                for (float &value : b)
                    value = std::ldexp(value, -20);
            } else if (fixture >= 40 && fixture < 60) {
                for (float &value : a)
                    value = std::ldexp(value, -30);
                for (float &value : b)
                    value = std::ldexp(value, 20);
            } else if (fixture >= 60 && fixture < 64) {
                // A single exceptional lane must retain the full BF16 range.
                a[3 * k + 5] = fixture % 2 ? std::ldexp(1.0f, 17) : std::ldexp(1.0f, -30);
            } else if (fixture >= 64 && fixture < 84) {
                // Mixed exponents exercise cancellation and FP32 accumulation.
                for (float &value : a)
                    value = std::ldexp(value, int(random() % 34) - 17);
                for (float &value : b)
                    value = std::ldexp(value, int(random() % 34) - 17);
            } else if (fixture >= 84) {
                // Exact FP16 subnormals must survive MMA, not just conversion.
                // Large B makes flushing even the smallest A observable.
                for (float &value : a)
                    value = std::ldexp(value, -17);
                for (float &value : b)
                    value = std::ldexp(value, 15);
            }
        }
        check(cudaMemcpyAsync(da, a.data(), a.size() * sizeof(float), cudaMemcpyHostToDevice,
                              stream));
        check(cudaMemcpyAsync(db, b.data(), b.size() * sizeof(float), cudaMemcpyHostToDevice,
                              stream));
        check(cudaMemcpyAsync(dc, c.data(), c.size() * sizeof(float), cudaMemcpyHostToDevice,
                              stream));
        // Poison output: every result must be overwritten on every replay.
        check(cudaMemsetAsync(dout, 0xff, 128 * sizeof(float), stream));
        check(cudaGraphLaunch(executable, stream));
        check(cudaMemcpyAsync(actual.data(), dout, 128 * sizeof(float), cudaMemcpyDeviceToHost,
                              stream));
        check(cudaStreamSynchronize(stream));
        for (int row = 0; row < 16; ++row) {
            for (int col = 0; col < 8; ++col) {
                double expected = c[row * 8 + col];
                double magnitude = std::abs(expected);
                for (int i = 0; i < k; ++i) {
                    const double term = double(a[row * k + i]) * b[i * 8 + col];
                    expected += term;
                    magnitude += std::abs(term);
                }
                const double error = std::abs(actual[row * 8 + col] - expected);
                const double tolerance = Kind == 0 ? 0 : 2e-6 * magnitude + 1e-7;
                if (!std::isfinite(actual[row * 8 + col]) || error > tolerance) {
                    if (failures < 3)
                        std::cerr << name << " fixture=" << fixture << " row=" << row
                                  << " col=" << col << " expected=" << expected
                                  << " actual=" << actual[row * 8 + col] << '\n';
                    ++failures;
                }
            }
        }
    }
    check(cudaGraphExecDestroy(executable));
    check(cudaGraphDestroy(graph));
    check(cudaStreamDestroy(stream));
    check(cudaFree(da));
    check(cudaFree(db));
    check(cudaFree(dc));
    check(cudaFree(dout));
    std::cout << name << ": " << failures << "/" << fixtures * 128
              << " mismatches (fixed-address graph replay)\n";
    return failures;
}

int main() {
    cudaDeviceProp device{};
    check(cudaGetDeviceProperties(&device, 0));
    if (device.major != 7 || device.minor != 5) {
        std::cerr << "This regression must run on SM75, not another GPU architecture\n";
        return 2;
    }
    int failures = run<0>() + run<1>() + run<2>();
#ifdef NINFER_CHECK_EXACT_GUARD
    int *device_failures, guard_failures = 0;
    check(cudaMalloc(&device_failures, sizeof(int)));
    check(cudaMemset(device_failures, 0, sizeof(int)));
    check_conversion_guard<<<256, 256>>>(device_failures);
    check(cudaGetLastError());
    check(cudaMemcpy(&guard_failures, device_failures, sizeof(int), cudaMemcpyDeviceToHost));
    check(cudaFree(device_failures));
    std::cout << "BF16 exact-conversion predicate: " << guard_failures << "/65536 mismatches\n";
    failures += guard_failures;
#endif
    std::cout << (failures ? "FAIL" : "PASS") << " SM75 MMA\n";
    return failures ? 1 : 0;
}
