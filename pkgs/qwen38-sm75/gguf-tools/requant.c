// Requantize one GGUF tensor's raw data: dequantize with its source type, then
// quantize with a target type, using ggml's reference kernels.
// usage: requant <src_type> <dst_type> <n_per_row> < in.raw > out.raw
#include "ggml.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

int main(int argc, char ** argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: %s <src_type_id> <dst_type_id> <n_per_row>\n", argv[0]);
        return 1;
    }
    const enum ggml_type src_type = (enum ggml_type) atoi(argv[1]);
    const enum ggml_type dst_type = (enum ggml_type) atoi(argv[2]);
    const int64_t n_per_row = atoll(argv[3]);

    const auto * ts = ggml_get_type_traits(src_type);
    const auto * td = ggml_get_type_traits(dst_type);
    if (!ts || !td || !ts->to_float || !td->from_float_ref) {
        fprintf(stderr, "unsupported types\n");
        return 1;
    }

    const size_t src_row_bytes = n_per_row / ts->blck_size * ts->type_size;
    const size_t dst_row_bytes = n_per_row / td->blck_size * td->type_size;

    std::vector<char>  src_row(src_row_bytes);
    std::vector<float> f32(n_per_row);
    std::vector<char>  dst_row(dst_row_bytes);

    size_t nrows = 0;
    while (fread(src_row.data(), 1, src_row_bytes, stdin) == src_row_bytes) {
        ts->to_float(src_row.data(), f32.data(), n_per_row);
        td->from_float_ref(f32.data(), dst_row.data(), n_per_row);
        if (fwrite(dst_row.data(), 1, dst_row_bytes, stdout) != dst_row_bytes) {
            fprintf(stderr, "write failed at row %zu\n", nrows);
            return 1;
        }
        nrows++;
    }
    fprintf(stderr, "requantized %zu rows: %s -> %s (row bytes %zu -> %zu)\n",
            nrows, ts->type_name, td->type_name, src_row_bytes, dst_row_bytes);
    return 0;
}
