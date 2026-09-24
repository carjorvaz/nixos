// Live W8 results must not depend on inactive shared-memory columns.
// The explicit PaddedZero schedule is the oracle; no floating tolerance is
// used.
#include "ops/linear/w8/w8_small_t_mma.cuh"
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <cuda_runtime.h>
#include <iostream>
#include <random>
#include <vector>

using namespace ninfer::ops::detail;
constexpr int Rows = 12288, Hidden = 2048, MaxWidth = 6;
static void check(cudaError_t status) {
  if (status != cudaSuccess) {
    std::cerr << cudaGetErrorString(status) << '\n';
    std::exit(2);
  }
}
static uint16_t bf16(float value) {
  uint32_t bits;
  std::memcpy(&bits, &value, sizeof(bits));
  return (bits + 0x7fff + ((bits >> 16) & 1)) >> 16;
}
struct FloatEpilogue {
  float *output;
  template <int Columns>
  __device__ void store(int row, const float (&values)[Columns]) const {
    for (int col = 0; col < Columns; ++col)
      output[col * Rows + row] = values[col];
  }
};
using Geometry = W8LinearGeometry<Rows, Hidden>;
template <int Width>
using ActiveSchedule = W8SmallTMmaDefaultSchedule<8, Width>;
template <int Width> struct ZeroSchedule : ActiveSchedule<Width> {
  static constexpr auto kActivationStage =
      W8SmallTMmaActivationStage::PaddedZero;
};
__global__ void poison_shared(unsigned bits) {
  extern __shared__ volatile unsigned memory[];
  for (int i = threadIdx.x; i < 65536 / 4; i += blockDim.x)
    memory[i] = bits;
}
template <int Width, class Schedule>
void launch(const uint16_t *x, const uint8_t *codes, const uint16_t *scales,
            uint16_t *dummy, float *output) {
  ninfer::ops::detail::w8_small_t_mma_kernel<Geometry, Width, Schedule,
                                             W8ContiguousOutput, FloatEpilogue>
      <<<Rows / 16, Schedule::kThreads>>>(
          reinterpret_cast<const __nv_bfloat16 *>(x), codes,
          reinterpret_cast<const uint8_t *>(scales),
          W8ContiguousOutput{reinterpret_cast<__nv_bfloat16 *>(dummy), Rows},
          FloatEpilogue{output});
  check(cudaGetLastError());
  check(cudaDeviceSynchronize());
}
int main() {
  cudaDeviceProp properties{};
  check(cudaGetDeviceProperties(&properties, 0));
  if (properties.major != 7 || properties.minor != 5)
    return 2;
  check(cudaFuncSetAttribute(
      poison_shared, cudaFuncAttributeMaxDynamicSharedMemorySize, 65536));
  std::vector<uint8_t> codes(Rows * Hidden);
  std::vector<uint16_t> scales(Rows * Hidden / 32), x(Hidden * MaxWidth);
  const uint16_t scale_choices[] = {0x3800, 0x3a00, 0x3c00, 0x3d00};
  for (int row = 0; row < Rows; ++row) {
    unsigned mix = row ^ (row >> 8) ^ (row >> 16);
    for (int k = 0; k < Hidden; ++k) {
      unsigned char code =
          (mix * 37 + (k / 32) * 29 + (k % 32) * 17 + 1901) & 255;
      codes[row * Hidden + k] = code == 0x80 ? 0x81 : code;
    }
    for (int k = 0; k < Hidden / 32; ++k)
      scales[row * (Hidden / 32) + k] =
          scale_choices[(row ^ (row >> 8) ^ k ^ 1901) & 3];
  }
  std::mt19937 random(1903);
  std::uniform_real_distribution<float> distribution(-0.01f, 0.01f);
  for (auto &value : x)
    value = bf16(distribution(random));
  uint8_t *dcodes;
  uint16_t *dscales, *dx, *dummy;
  float *output;
  check(cudaMalloc(&dcodes, codes.size()));
  check(cudaMalloc(&dscales, scales.size() * 2));
  check(cudaMalloc(&dx, x.size() * 2));
  check(cudaMalloc(&dummy, Rows * MaxWidth * 2));
  check(cudaMalloc(&output, Rows * MaxWidth * 4));
  check(cudaMemcpy(dcodes, codes.data(), codes.size(), cudaMemcpyHostToDevice));
  check(cudaMemcpy(dscales, scales.data(), scales.size() * 2,
                   cudaMemcpyHostToDevice));
  check(cudaMemcpy(dx, x.data(), x.size() * 2, cudaMemcpyHostToDevice));
  int failures = 0;
  for (int width = 1; width <= MaxWidth; ++width) {
    std::vector<float> reference(Rows * width), actual(reference.size());
    for (unsigned poison : {0u, 0x7fc17fc1u, 0x477f477fu, 0xffffffffu}) {
      for (bool padded : {true, false}) {
        // Poison output before shared storage: the fill may itself use a
        // kernel.
        check(cudaMemset(output, 0xff, actual.size() * sizeof(float)));
        poison_shared<<<properties.multiProcessorCount * 8, 256, 65536>>>(
            poison);
        check(cudaGetLastError());
        check(cudaDeviceSynchronize());
        // Instantiate every speculative width, keeping all device addresses
        // fixed.
#define RUN_WIDTH(N)                                                           \
  case N:                                                                      \
    if (padded)                                                                \
      launch<N, ZeroSchedule<N>>(dx, dcodes, dscales, dummy, output);          \
    else                                                                       \
      launch<N, ActiveSchedule<N>>(dx, dcodes, dscales, dummy, output);        \
    break
        switch (width) {
          RUN_WIDTH(1);
          RUN_WIDTH(2);
          RUN_WIDTH(3);
          RUN_WIDTH(4);
          RUN_WIDTH(5);
          RUN_WIDTH(6);
        }
#undef RUN_WIDTH
        check(cudaMemcpy(actual.data(), output, actual.size() * 4,
                         cudaMemcpyDeviceToHost));
        if (poison == 0 && padded)
          reference = actual;
        int different = 0;
        float largest = 0;
        for (size_t i = 0; i < actual.size(); ++i) {
          if (!std::isfinite(actual[i]) || actual[i] != reference[i]) {
            ++different;
            largest = std::fmax(largest, std::fabs(actual[i] - reference[i]));
          }
        }
        std::cout << "width=" << width << ' '
                  << (padded ? "PaddedZero" : "Default") << " poison=0x"
                  << std::hex << poison << std::dec << " changed=" << different
                  << " max=" << largest << '\n';
        failures += different;
      }
    }
  }
  check(cudaFree(dcodes));
  check(cudaFree(dscales));
  check(cudaFree(dx));
  check(cudaFree(dummy));
  check(cudaFree(output));
  return failures ? 1 : 0;
}
