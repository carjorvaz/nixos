#!/usr/bin/env python3
"""Add one raw tensor to a GGUF file, copying metadata and existing tensors verbatim.

usage: gguf-add-tensor.py in.gguf out.gguf name type_id raw_file dim0 dim1 ...
"""
import struct
import sys

SIZES = {0: 1, 1: 1, 2: 2, 3: 2, 4: 4, 5: 4, 6: 4, 7: 1, 10: 8, 11: 8, 12: 8}


def read_string(f):
    (n,) = struct.unpack("<Q", f.read(8))
    return f.read(n)


def skip_value(f, t):
    if t == 8:  # string
        (n,) = struct.unpack("<Q", f.read(8))
        f.seek(n, 1)
    elif t == 9:  # array
        (et,) = struct.unpack("<I", f.read(4))
        (n,) = struct.unpack("<Q", f.read(8))
        if et == 8:
            for _ in range(n):
                (l,) = struct.unpack("<Q", f.read(8))
                f.seek(l, 1)
        elif et == 9:
            raise ValueError("nested arrays unsupported")
        else:
            f.seek(SIZES[et] * n, 1)
    else:
        f.seek(SIZES[t], 1)


def main():
    in_path, out_path, name = sys.argv[1], sys.argv[2], sys.argv[3]
    type_id = int(sys.argv[4])
    raw_path = sys.argv[5]
    dims = [int(x) for x in sys.argv[6:]]
    name_b = name.encode("utf-8")

    with open(in_path, "rb") as f:
        assert f.read(4) == b"GGUF"
        (version,) = struct.unpack("<I", f.read(4))
        (n_tensors,) = struct.unpack("<Q", f.read(8))
        (n_kv,) = struct.unpack("<Q", f.read(8))

        alignment = 32
        for _ in range(n_kv):
            key = read_string(f)
            (t,) = struct.unpack("<I", f.read(4))
            if key == b"general.alignment":
                assert t == 4
                (alignment,) = struct.unpack("<I", f.read(4))
            else:
                skip_value(f, t)
        meta_end = f.tell()
        f.seek(0)
        meta_bytes = f.read(meta_end)

        tensors = []
        for _ in range(n_tensors):
            tn = read_string(f)
            (nd,) = struct.unpack("<I", f.read(4))
            tdims = [struct.unpack("<Q", f.read(8))[0] for _ in range(nd)]
            (tt,) = struct.unpack("<I", f.read(4))
            (toff,) = struct.unpack("<Q", f.read(8))
            tensors.append((tn, tdims, tt, toff))
        info_end = f.tell()

        data_start = (info_end + alignment - 1) // alignment * alignment
        assert data_start >= info_end
        f.seek(0, 2)
        file_size = f.tell()
        data_size = file_size - data_start
        new_off = (data_size + alignment - 1) // alignment * alignment

    with open(raw_path, "rb") as g:
        raw = g.read()

    # emit
    with open(in_path, "rb") as f, open(out_path, "wb") as o:
        f.seek(0)
        header = bytearray()
        header += b"GGUF"
        header += struct.pack("<I", version)
        header += struct.pack("<Q", n_tensors + 1)
        header += struct.pack("<Q", n_kv)
        header += meta_bytes[24:meta_end]  # metadata bytes verbatim (after the 24-byte preamble)
        for tn, tdims, tt, toff in tensors:
            header += struct.pack("<Q", len(tn)) + tn
            header += struct.pack("<I", len(tdims))
            for d in tdims:
                header += struct.pack("<Q", d)
            header += struct.pack("<I", tt)
            header += struct.pack("<Q", toff)
        header += struct.pack("<Q", len(name_b)) + name_b
        header += struct.pack("<I", len(dims))
        for d in dims:
            header += struct.pack("<Q", d)
        header += struct.pack("<I", type_id)
        header += struct.pack("<Q", new_off)
        o.write(header)
        pad = (alignment - len(header) % alignment) % alignment
        o.write(b"\0" * pad)
        # copy original data section
        f.seek(data_start)
        left = data_size
        while left:
            chunk = f.read(min(1 << 24, left))
            if not chunk:
                break
            o.write(chunk)
            left -= len(chunk)
        # pad to the new tensor offset, then write it
        cur = data_size
        if new_off > cur:
            o.write(b"\0" * (new_off - cur))
        o.write(raw)
        tail = (alignment - len(raw) % alignment) % alignment
        o.write(b"\0" * tail)
    print("wrote %s: +1 tensor (%s, type %d, dims %s, %d bytes) at offset %d" %
          (out_path, name, type_id, dims, len(raw), new_off))
    return 0


if __name__ == "__main__":
    sys.exit(main())
