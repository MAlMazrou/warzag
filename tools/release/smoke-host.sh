#!/bin/bash
# Smoke-test the engine's game host (Warzag.app; its loader must be arm64) headless, in a throwaway prefix. Opens no
# window and touches nothing outside its own temporary directory; Steam and Warframe are never involved.
#
#   tools/release/smoke-host.sh <Warzag.app> [--keep]
#
#   1. Contents/MacOS/wine --version
#   2. a scratch prefix booted with WineKit's environment (neutron's NEUTRON_* switches, Wine Mono and Gecko off, the
#      DXMT overlay through WINEDLLPATH_PREPEND), plus Wine's null display driver (nothing is shown) and no menu
#      builder. winemetal, nvapi64, nvngx and lsteamclient get their system32 placeholders from the host.
#   3. lsteamclient.dll and winemetal.dll loaded with `regsvr32 /s`, which finds no DllRegisterServer and exits 4.
#      Both DLLs ignore a failed unixlib load, so dyld's own log (DYLD_PRINT_LIBRARIES) must show the host's signed
#      lsteamclient.so and winemetal.so mapped into the Wine process.
# --keep keeps the scratch prefix and logs.
set -euo pipefail

HOST=""
KEEP=0
while [ $# -gt 0 ]; do
    case "$1" in
        --keep) KEEP=1; shift ;;
        -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
        -*) echo "unknown option: $1" >&2; exit 2 ;;
        *) [ -z "$HOST" ] || { echo "only one host" >&2; exit 2; }; HOST="$1"; shift ;;
    esac
done
[ -n "$HOST" ] || { echo "usage: $0 <Warzag.app> [--keep]" >&2; exit 2; }
die() { echo "error: $*" >&2; exit 1; }
[ -x "$HOST/Contents/MacOS/wine" ] || die "$HOST has no Contents/MacOS/wine"
# Wine resolves its own location, so dyld logs real paths.
HOST="$(cd "$HOST" && pwd -P)"
C="$HOST/Contents"
case "$(lipo -archs "$C/MacOS/wine" 2>/dev/null || true)" in
    arm64) ;;
    *) die "$C/MacOS/wine is not arm64-only" ;;
esac

S="$(mktemp -d -t warzag-smoke)"
S="$(cd "$S" && pwd -P)"
PREFIX="$S/prefix"
cleanup() {
    if [ -d "$PREFIX" ]; then
        env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin WINEPREFIX="$PREFIX" "$C/MacOS/wineserver" -k 2>/dev/null || true
    fi
    if [ "$KEEP" = 1 ]; then echo "kept $S" >&2; else rm -rf "$S"; fi
}
trap cleanup EXIT

failed=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; failed=1; }

# Runs a command for at most $1 seconds (a hung wineboot must not hang a release).
with_timeout() {
    local seconds="$1" pid waited=0
    shift
    "$@" &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$waited" -ge "$seconds" ]; then
            kill -9 "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
            return 124
        fi
        sleep 1
        waited=$((waited + 1))
    done
    wait "$pid"
}

# The engine switches (WineKit's WineEnvironment.neutronDefaults).
SWITCHES=(NEUTRON_PRECISE_TIMERS=1 NEUTRON_FAST_QPC=1 NEUTRON_RAW_MOUSE=1 NEUTRON_NATIVE_FULLSCREEN=0
          NEUTRON_RENDER_SCALE=1 NEUTRON_MSYNC=0)

# The tool-run environment (WineKit's), built from scratch so nothing from this shell leaks in. Only ever called
# through with_timeout, whose background subshell it replaces (exec), so a kill reaches Wine itself.
wine_env() {
    exec env -i HOME="$HOME" USER="${USER:-$(id -un)}" LOGNAME="${USER:-$(id -un)}" TMPDIR="${TMPDIR:-/tmp}" \
        PATH=/usr/bin:/bin:/usr/sbin:/sbin LANG=en_US.UTF-8 \
        WINEPREFIX="$PREFIX" "${SWITCHES[@]}" WINEDEBUG=-all SteamDeck=0 \
        WINEDLLPATH_PREPEND="$C/renderers/dxmt" \
        WINEDLLOVERRIDES="mscoree,mshtml=;winemenubuilder.exe=d;winemac.drv=d" \
        "$@"
}

# 1. The loader runs at all.
if version="$(with_timeout 60 wine_env "$C/MacOS/wine" --version 2>"$S/version.err")"; then
    pass "wine --version: $version"
else
    fail "wine --version (see below)"; sed 's/^/      /' "$S/version.err"
fi

# 2. A headless prefix.
mkdir -p "$PREFIX"
if with_timeout 600 wine_env "$C/MacOS/wine" wineboot -i >"$S/wineboot.log" 2>&1 \
    && with_timeout 120 wine_env "$C/MacOS/wineserver" -w; then
    pass "wineboot -i in a scratch prefix (headless)"
else
    fail "wineboot -i (log: $S/wineboot.log)"; KEEP=1
    exit 1
fi
SYS32="$PREFIX/drive_c/windows/system32"
for dll in winemetal.dll nvapi64.dll nvngx.dll; do
    [ -f "$SYS32/$dll" ] || cp "$C/renderers/dxmt/aarch64-windows/$dll" "$SYS32/$dll"
done
[ -f "$SYS32/lsteamclient.dll" ] || cp "$C/lib/wine/aarch64-windows/lsteamclient.dll" "$SYS32/lsteamclient.dll"

# 3. The unixlibs load.
load_check() { # load_check <dll> <unixlib path inside the host>
    local dll="$1" unixlib="$C/$2" log="$S/${1%.dll}.log" status=0 authority
    [ -f "$unixlib" ] || { fail "$dll: $unixlib is missing"; return; }
    details="$(codesign -dv --verbose=2 "$unixlib" 2>&1 || true)"
    authority="$(sed -n '1,/^Authority=/s/^Authority=//p' <<<"$details")"
    if [ -z "$authority" ]; then
        case "$details" in *Signature=adhoc*) authority="ad hoc" ;; *) authority="unsigned" ;; esac
    fi
    with_timeout 120 wine_env DYLD_PRINT_LIBRARIES=1 "$C/MacOS/wine" regsvr32 /s "$dll" >"$log" 2>&1 || status=$?
    if [ "$status" -ne 4 ] && [ "$status" -ne 0 ]; then
        fail "$dll: regsvr32 exit $status (3 = the DLL did not load; log: $log)"; KEEP=1
    elif grep -Fq "$unixlib" "$log"; then
        pass "$dll loaded and dyld mapped ${unixlib#"$C"/} (signed: $authority)"
    else
        fail "$dll loaded but dyld never mapped $unixlib (log: $log)"; KEEP=1
    fi
    if grep -Eiq 'code signature|not valid for use in process|library load disallowed' "$log"; then
        fail "$dll: dyld reported a code-signing problem (log: $log)"; KEEP=1
    fi
}
load_check lsteamclient.dll "lib/wine/aarch64-unix/lsteamclient.so"
load_check winemetal.dll "renderers/dxmt/aarch64-unix/winemetal.so"

with_timeout 60 wine_env "$C/MacOS/wineserver" -k 2>/dev/null || true
exit $failed
