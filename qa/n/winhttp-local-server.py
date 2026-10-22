#!/usr/bin/env python3
"""Local HTTP server for the bug-59605 class of WinHTTP regressions (no traffic to DE).

Usage: qa/n/winhttp-local-server.py <port> <ready-file>

Serves deterministic bodies on 127.0.0.1 in the shapes a game launcher's downloader meets:
  /len/<MiB>.lzma       Content-Length body of <MiB> MiB that starts like an LZMA-alone stream; honours Range
  /chunked/<MiB>.lzma   the same body with Transfer-Encoding: chunked (uneven chunk sizes)
  /gzip/<MiB>.<ext>     the same body, gzip-encoded when the request accepts gzip (Content-Encoding: gzip)
  /slow/<MiB>.lzma      Content-Length body sent in 64 KiB pieces with 20 ms pauses
  /close/<MiB>.lzma     connection-delimited body (no length, Connection: close)
Every response also carries X-Original-Length (the full uncompressed body) and, for bodies up to 16 MiB,
X-Body-FNV (64-bit FNV-1a of it), which qa/n/winhttp-loop checks. Writes <ready-file> once listening.
"""
import gzip
import http.server
import re
import socketserver
import sys
import time

LZMA_HEADER = bytes([0x5D, 0x00, 0x00, 0x10, 0x00]) + b"\xff" * 8  # props, 1 MiB dictionary, unknown size
FNV_LIMIT = 16 * 1024 * 1024


def body(mib):
    block = bytes((i * 131 + (i >> 9)) & 0xFF for i in range(65536))
    data = bytearray(LZMA_HEADER)
    while len(data) < mib * 1024 * 1024:
        data += block
    return bytes(data[: mib * 1024 * 1024])


def fnv1a(data):
    h = 0xCBF29CE484222325
    for b in data:
        h = ((h ^ b) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return h


BODIES, HASHES, GZIPPED = {}, {}, {}


def get_body(mib):
    if mib not in BODIES:
        BODIES[mib] = body(mib)
    return BODIES[mib]


def get_hash(mib):
    if mib not in HASHES and mib * 1024 * 1024 <= FNV_LIMIT:
        HASHES[mib] = fnv1a(get_body(mib))
    return HASHES.get(mib)


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.command, fmt % args))

    def common_headers(self, mib, data):
        self.send_header("X-Original-Length", str(len(data)))
        h = get_hash(mib)
        if h is not None:
            self.send_header("X-Body-FNV", "0x%016X" % h)

    def do_GET(self):
        parts = self.path.strip("/").split("/")
        try:
            kind, mib = parts[0], int(parts[1].split(".")[0])
        except (IndexError, ValueError):
            self.send_error(404)
            return
        mib = max(1, min(mib, 512))
        data = get_body(mib)
        if kind == "len":
            m = re.match(r"bytes=(\d+)-(\d+)$", self.headers.get("Range", ""))
            if m:
                a, b = int(m.group(1)), min(int(m.group(2)), len(data) - 1)
                piece = data[a:b + 1]
                self.send_response(206)
                self.send_header("Content-Range", "bytes %d-%d/%d" % (a, b, len(data)))
                self.send_header("Content-Length", str(len(piece)))
                self.common_headers(mib, data)
                self.end_headers()
                self.wfile.write(piece)
            else:
                self.send_response(200)
                self.send_header("Content-Length", str(len(data)))
                self.common_headers(mib, data)
                self.end_headers()
                self.wfile.write(data)
        elif kind == "chunked":
            self.send_response(200)
            self.send_header("Transfer-Encoding", "chunked")
            self.common_headers(mib, data)
            self.end_headers()
            pos, n = 0, 1
            while pos < len(data):
                size = min(len(data) - pos, 1000 + (n * 7919) % 70000)
                self.wfile.write(b"%x\r\n" % size + data[pos:pos + size] + b"\r\n")
                pos += size
                n += 1
            self.wfile.write(b"0\r\n\r\n")
        elif kind == "gzip":
            if "gzip" in self.headers.get("Accept-Encoding", ""):
                if mib not in GZIPPED:
                    GZIPPED[mib] = gzip.compress(data, compresslevel=1, mtime=0)
                z = GZIPPED[mib]
                sys.stderr.write("gzip-encoded response for %s (%d bytes on the wire)\n" % (self.path, len(z)))
                self.send_response(200)
                self.send_header("Content-Encoding", "gzip")
                self.send_header("Content-Length", str(len(z)))
                self.common_headers(mib, data)
                self.end_headers()
                self.wfile.write(z)
            else:
                self.send_response(200)
                self.send_header("Content-Length", str(len(data)))
                self.common_headers(mib, data)
                self.end_headers()
                self.wfile.write(data)
        elif kind == "slow":
            self.send_response(200)
            self.send_header("Content-Length", str(len(data)))
            self.common_headers(mib, data)
            self.end_headers()
            for pos in range(0, len(data), 65536):
                self.wfile.write(data[pos:pos + 65536])
                self.wfile.flush()
                time.sleep(0.02)
        elif kind == "close":
            self.send_response(200)
            self.send_header("Connection", "close")
            self.common_headers(mib, data)
            self.end_headers()
            self.wfile.write(data)
            self.close_connection = True
        else:
            self.send_error(404)


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    port, ready = int(sys.argv[1]), sys.argv[2]
    srv = Server(("127.0.0.1", port), Handler)
    for mib in (1, 4, 8):  # warm the hashes the loop test uses
        get_hash(mib)
    open(ready, "w").write("ready\n")
    srv.serve_forever()


if __name__ == "__main__":
    main()
