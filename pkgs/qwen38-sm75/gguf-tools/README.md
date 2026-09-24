# GGUF surgery tools

Small stdlib-only helpers used to build the fast-draft model for the Turing
campaign (see `docs/exec-plans/active/llamacpp-parity.md`).

- `gguf-dump-tensor.py in.gguf tensor.name out.raw` - extract one tensor's raw
  bytes (works for any quant type).
- `requant.c` - dequantize a raw tensor with ggml's reference kernels and
  re-quantize it to another type:

  ```
  c++ -O2 -I ggml/include -o requant requant.c -L <build>/bin -lggml-base -Wl,-rpath,<build>/bin
  ./requant <src_type_id> <dst_type_id> <n_per_row> < in.raw > out.raw
  ```

  Type ids are the `ggml_type` enum (Q4_0=2, Q4_K=12, Q6_K=14, ...).
- `gguf-add-tensor.py in.gguf out.gguf name type_id raw_file dim0 dim1 ...` -
  produce a copy of `in.gguf` with one extra tensor appended. Metadata and the
  existing tensor data section are copied verbatim, so the result loads in
  llama.cpp unchanged.

Worked example (add a Q4_K draft head to a Qwen3.8 MTP model):

```
python3 gguf-dump-tensor.py Qwen3.8-27B-UD-Q4_K_M.gguf output.weight head_q6k.raw
./requant 14 12 5120 < head_q6k.raw > head_q4k.raw
python3 gguf-add-tensor.py Qwen3.8-27B-UD-Q4_K_M.gguf fastdraft.gguf \
    blk.64.nextn.shared_head_head.weight 12 head_q4k.raw 5120 248320
```

The draft then reads 682 MiB instead of 994 MiB per draft pass (+7% decode on
MTP4 with unchanged acceptance).
