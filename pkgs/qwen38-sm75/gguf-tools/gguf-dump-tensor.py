#!/usr/bin/env python3
"""Dump one tensor's raw bytes from a GGUF. usage: gguf-dump-tensor.py in.gguf name out.raw"""
import struct, sys

def read_string(f):
    (n,) = struct.unpack("<Q", f.read(8))
    return f.read(n)

def skip_value(f, t):
    sizes = {0:1,1:1,2:2,3:2,4:4,5:4,6:4,7:1,10:8,11:8,12:8}
    if t == 8:
        (n,) = struct.unpack("<Q", f.read(8)); f.seek(n, 1)
    elif t == 9:
        (et,) = struct.unpack("<I", f.read(4)); (n,) = struct.unpack("<Q", f.read(8))
        if et == 8:
            for _ in range(n):
                (l,) = struct.unpack("<Q", f.read(8)); f.seek(l, 1)
        else:
            f.seek(sizes[et] * n, 1)
    else:
        f.seek(sizes[t], 1)

def main():
    path, want, out = sys.argv[1], sys.argv[2].encode(), sys.argv[3]
    with open(path, "rb") as f:
        assert f.read(4) == b"GGUF"
        struct.unpack("<I", f.read(4))
        n_tensors, n_kv = struct.unpack("<QQ", f.read(16))
        align = 32
        for _ in range(n_kv):
            k = read_string(f); (t,) = struct.unpack("<I", f.read(4))
            if k == b"general.alignment":
                (align,) = struct.unpack("<I", f.read(4))
            else:
                skip_value(f, t)
        info_end = None
        hit = None
        for _ in range(n_tensors):
            if info_end is None and hit is None:
                info_end = f.tell()
            tn = read_string(f)
            (nd,) = struct.unpack("<I", f.read(4))
            dims = [struct.unpack("<Q", f.read(8))[0] for _ in range(nd)]
            (tt,) = struct.unpack("<I", f.read(4))
            (off,) = struct.unpack("<Q", f.read(8))
            if tn == want:
                hit = (dims, tt, off)
        end = f.tell()
    data_start = (end + align - 1) // align * align
    dims, tt, off = hit
    nel = 1
    for d in dims:
        nel *= d
    bpe = {0:4.0,1:2.0,2:18/32,3:20/32,6:22/32,7:24/32,8:34/32,9:36/32,10:84/256,11:110/256,
           12:144/256,13:176/256,14:210/256,15:292/256,16:66/256,17:74/256,18:98/256,19:50/256,
           20:18/32,21:110/256,22:82/256,23:136/256,30:2.0}
    nbytes = int(nel * bpe[tt])
    with open(path, "rb") as f:
        f.seek(data_start + off)
        data = f.read(nbytes)
    assert len(data) == nbytes, (len(data), nbytes)
    with open(out, "wb") as g:
        g.write(data)
    print("dumped %s: dims=%s type=%d bytes=%d" % (want.decode(), dims, tt, nbytes))

if __name__ == "__main__":
    main()
