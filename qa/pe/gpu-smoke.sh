#!/bin/bash
# GPU smoke test across renderers: runs wz-d3d11-smoke.exe on the Warzag runtime once per renderer and checks
# that the intended implementation really drew the frames (DXMT or wined3d), and that DXMT's DXGI reports
# Apple's vendor ID without NVEXT and NVIDIA's with it. Prints one verdict and JSON line per renderer; exits 1 if
# any renderer failed.
#
#   qa/pe/gpu-smoke.sh [--prefix <dir>] [--frames N] [renderer...]     (default: dxmt dxmt-nvext)
#
# Needs build/pe (make -C qa/pe) and build/n/Warzag.app (runtime/n/make-host.sh). Opens a window per run.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CACHE="${WARZAG_CACHE:-$HOME/Library/Caches/warzag-build}"
PREFIX="$CACHE/prefixes/qa-pe"
FRAMES=300
EXE="$ROOT/build/pe/wz-d3d11-smoke.exe"

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix) PREFIX="$2"; shift 2 ;;
        --frames) FRAMES="$2"; shift 2 ;;
        -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
        -*) echo "unknown option: $1" >&2; exit 2 ;;
        *) break ;;
    esac
done
[ $# -gt 0 ] || set -- dxmt dxmt-nvext
[ -f "$EXE" ] || { echo "error: $EXE missing (run make -C qa/pe)" >&2; exit 1; }

# What each renderer must show, as a jq condition on the result line. The vendor ID only means something with DXMT's
# own dxgi.dll (Wine's DXGI reports 0x10DE too), and only as a pair: DXMT_ENABLE_NVEXT is the one difference between
# the dxmt and dxmt-nvext runs, so Apple's ID in one and NVIDIA's in the other show that NVEXT made the change. A
# DXMT_CONFIG vendor override left in the environment changes both, and fails the dxmt run.
expect() {
    case "$1" in
        dxmt) echo '.d3d11_impl == "dxmt" and .dxgi_impl == "dxmt" and .vendor_id == "0x106B"' ;;
        dxmt-nvext) echo '.d3d11_impl == "dxmt" and .dxgi_impl == "dxmt" and .vendor_id == "0x10DE"' ;;
        wined3d) echo '.d3d11_impl == "wined3d" and .dxgi_impl == "wined3d"' ;;
        *) echo "error: unknown renderer $1" >&2; exit 2 ;;
    esac
}

for renderer in "$@"; do expect "$renderer" >/dev/null; done # reject unknown names before any run

wine() { "$ROOT/runtime/dev-wine.sh" --prefix "$PREFIX" "$@"; }
# A new prefix is booted with the DXMT overlay active, so wineboot also copies DXMT's winemetal.dll, nvapi64.dll and
# nvngx.dll into system32: the placeholders Wine needs before it loads them from the overlay. In a prefix booted
# without them every DXMT run fails at stage d3d11_load.
if [ ! -f "$PREFIX/system.reg" ]; then
    WINEDLLOVERRIDES='mscoree,mshtml=' wine --renderer dxmt wineboot -i >/dev/null 2>&1 \
        || { echo "error: wineboot -i failed for $PREFIX" >&2; exit 1; }
fi

failed=0
for renderer in "$@"; do
    condition="$(expect "$renderer")"
    # stdout carries the result line; Wine and DXMT log to stderr.
    out="$(wine --renderer "$renderer" "$EXE" --frames "$FRAMES" 2>/dev/null)" && status=0 || status=$?
    line="$(tail -n 1 <<<"$out")"
    if [ $status -eq 0 ] && jq -e ".ok == true and ($condition)" <<<"$line" >/dev/null 2>&1; then
        verdict=PASS
    else
        verdict=FAIL
        failed=1
    fi
    printf '%s  %-10s  exit=%d  %s\n' "$verdict" "$renderer" "$status" "$line"
done
exit $failed
