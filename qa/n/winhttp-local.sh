#!/bin/bash
# WinHTTP download shapes against a local server, for the class of Wine bug 59605 (DE's launcher stops downloading on
# Wine 11.5+, which reworked WinHTTP's read path). Every request goes to qa/n/winhttp-local-server.py on 127.0.0.1.
#
#   qa/n/winhttp-local.sh [--host <Warzag.app>] [--prefix <dir>] [--mib N]
#
# Part 1, build/pe/wz-winhttp-probe.exe --url, one request per shape: Content-Length, chunked, gzip-encoded (raw),
#   slow drip, connection-delimited. A pass means the whole body arrived.
# Part 2, qa/n/winhttp-loop (x86-64, under FEX like Launcher.exe), the launcher's own WinHTTP pattern (synchronous,
#   WinHttpReadData without WinHttpQueryDataAvailable, one session, keep-alive), each body checked by size and
#   FNV-1a hash: a sequence of files; gzip bodies with WINHTTP_OPTION_DECOMPRESSION; files in 1 MiB Range pieces.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CACHE="${WARZAG_CACHE:-$HOME/Library/Caches/warzag-build}"
MAIN="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null | sed 's#/\.git$##' || true)"
[ -n "$MAIN" ] && [ -d "$MAIN" ] || MAIN="$ROOT"
HOST="$MAIN/build/n/Warzag.app"
PREFIX="$CACHE/prefixes/n-smoke"
MIB=64
while [ $# -gt 0 ]; do
    case "$1" in
        --host) HOST="$2"; shift 2 ;;
        --prefix) PREFIX="$2"; shift 2 ;;
        --mib) MIB="$2"; shift 2 ;;
        -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done
PROBE="$MAIN/build/pe/wz-winhttp-probe.exe"
LOOP="$CACHE/work/n/qa/wz-winhttp-loop.exe"
GCC="$(brew --prefix)/bin/x86_64-w64-mingw32-gcc"
if [ ! -f "$LOOP" ] || [ "$ROOT/qa/n/winhttp-loop/main.c" -nt "$LOOP" ]; then
    mkdir -p "$(dirname "$LOOP")"
    env -u CFLAGS -u LDFLAGS "$GCC" -std=gnu17 -O2 -Wall -Wextra -Werror -municode -mconsole -DUNICODE -D_UNICODE \
        -I"$ROOT/qa/pe/common" -o "$LOOP" "$ROOT/qa/n/winhttp-loop/main.c" -static-libgcc -Wl,--no-insert-timestamp -lwinhttp
fi
OUT="$CACHE/work/n/winhttp-local/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
PORT=18559
python3 -I "$ROOT/qa/n/winhttp-local-server.py" "$PORT" "$OUT/ready" 2> "$OUT/server.log" &
SERVER=$!
trap 'kill "$SERVER" 2>/dev/null || true' EXIT
for _ in $(seq 1 300); do [ -f "$OUT/ready" ] && break; sleep 0.1; done
[ -f "$OUT/ready" ] || { echo "error: server did not start" >&2; exit 1; }
wine() { "$ROOT/runtime/dev-wine.sh" --host "$HOST" --prefix "$PREFIX" --renderer wined3d "$@"; }

expect_bytes=$((MIB * 1024 * 1024))
fail=0
for case in "len/$MIB.lzma" "chunked/$MIB.lzma" "gzip/$MIB.bin" "slow/8.lzma" "close/$MIB.lzma"; do
    name="${case%%/*}"
    wine "$PROBE" --url "http://127.0.0.1:$PORT/$case" > "$OUT/$name.out" 2> "$OUT/$name.log" && st=0 || st=$?
    line="$(tr -d '\r' < "$OUT/$name.out" | grep '^{' | tail -n 1 || true)"
    want="$expect_bytes"
    [ "$name" = slow ] && want=$((8 * 1024 * 1024))
    case "$name" in
        gzip) cond='.ok == true' ;;                      # compressed size varies; Content-Length checks it
        *) cond=".ok == true and .bytes == $want" ;;
    esac
    if [ "$st" = 0 ] && jq -e "$cond" <<<"$line" >/dev/null 2>&1; then v=PASS; else v=FAIL; fail=1; fi
    printf 'probe %-8s %s exit=%s %s\n' "$name" "$v" "$st" "$line"
done

B="http://127.0.0.1:$PORT"
loop() {  # loop <name> <args...>
    local name="$1" st line
    shift
    wine "$LOOP" "$@" > "$OUT/loop-$name.out" 2> "$OUT/loop-$name.log" && st=0 || st=$?
    line="$(tr -d '\r' < "$OUT/loop-$name.out" | grep '"summary"' | tail -n 1 || true)"
    if [ "$st" = 0 ] && jq -e '.ok == true' <<<"$line" >/dev/null 2>&1 \
        && [ "$(tr -d '\r' < "$OUT/loop-$name.out" | grep -c '"hash_ok":true')" -ge 1 ]; then v=PASS; else v=FAIL; fail=1; fi
    printf 'loop  %-10s %s exit=%s %s\n' "$name" "$v" "$st" "$line"
}
loop sequence --url "$B/len/8.lzma" --url "$B/chunked/8.lzma" --url "$B/len/4.lzma" --url "$B/close/8.lzma" \
    --url "$B/len/1.lzma" --url "$B/chunked/4.lzma" --url "$B/slow/1.lzma" --url "$B/len/8.lzma"
loop decompress --decompress --url "$B/gzip/8.bin" --url "$B/gzip/4.bin" --url "$B/len/8.lzma" --url "$B/gzip/1.bin"
loop range --range 1048576 --url "$B/len/8.lzma" --url "$B/len/4.lzma" --url "$B/len/1.lzma"
echo "results: $OUT"
exit $fail
