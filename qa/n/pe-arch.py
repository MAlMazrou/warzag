#!/usr/bin/env python3
"""Classify Windows PE files by the code they contain: x86, x64, arm64, arm64ec or arm64x.

Usage: qa/n/pe-arch.py <file or directory> ...   (prints "<kind>\t<path>" per PE file; non-PE files are skipped)

`file` cannot tell these apart: an ARM64EC image has the AMD64 machine type in its header, an ARM64X image the
ARM64 one; both carry CHPE metadata (the CHPEMetadataPointer of the load config) that a plain x64 or arm64 image
does not.
"""
import os
import struct
import sys

MACHINES = {0x14C: "x86", 0x8664: "x64", 0xAA64: "arm64", 0xA641: "arm64ec", 0xA64E: "arm64x"}


def classify(path):
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError:
        return None
    if len(data) < 0x40 or data[:2] != b"MZ":
        return None
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    if pe + 24 > len(data) or data[pe:pe + 4] != b"PE\0\0":
        return None
    machine, nsections = struct.unpack_from("<HH", data, pe + 4)
    opt_size = struct.unpack_from("<H", data, pe + 20)[0]
    opt = pe + 24
    magic = struct.unpack_from("<H", data, opt)[0]
    kind = MACHINES.get(machine, f"machine-0x{machine:04x}")
    if magic != 0x20B:  # only PE32+ images can be hybrid
        return kind
    ndirs = struct.unpack_from("<I", data, opt + 108)[0]
    if ndirs <= 10:
        return kind
    lc_rva, lc_size = struct.unpack_from("<II", data, opt + 112 + 10 * 8)
    if not lc_rva:
        return kind
    sections = opt + opt_size
    offset = None
    for i in range(nsections):
        s = sections + 40 * i
        vsize, va, rawsize, rawptr = struct.unpack_from("<IIII", data, s + 8)
        if va <= lc_rva < va + max(vsize, rawsize):
            offset = rawptr + (lc_rva - va)
            break
    if offset is None or offset + 4 > len(data):
        return kind
    size = struct.unpack_from("<I", data, offset)[0]
    chpe = 0
    if size >= 0xC8 + 8 and offset + 0xD0 <= len(data):
        chpe = struct.unpack_from("<Q", data, offset + 0xC8)[0]
    if chpe:
        if machine == 0x8664:
            return "arm64ec"
        if machine == 0xAA64:
            return "arm64x"
    return kind


def main(argv):
    if not argv:
        print(__doc__.strip())
        return 2
    for top in argv:
        paths = [top]
        if os.path.isdir(top):
            paths = [os.path.join(d, n) for d, _, names in os.walk(top) for n in sorted(names)]
        for p in paths:
            if os.path.islink(p):
                continue
            kind = classify(p)
            if kind:
                print(f"{kind}\t{p}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
