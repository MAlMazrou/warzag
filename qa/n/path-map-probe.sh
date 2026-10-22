#!/bin/bash
# Check the engine build's path maps (runtime/n/path-maps.sh) on small probes instead of a full engine build. Each probe
# compiles sources that record their own path (__FILE__, asserts, debug info) with the build's flags, in a temporary
# folder under ~/Library/Caches. tools/release/forbidden-scan.py --personal must find no build path in the results and
# must find one in each probe's control (built without the maps unless noted), so the check cannot pass blind.
#
#   qa/n/path-map-probe.sh [--keep]
#
#   mac-c      Apple clang C (nettle's -ggdb3 in-tree, Wine's unix side out-of-tree) linked with -oso_prefix, then
#              strip -S as for the deps; control: no maps and no -oso_prefix
#   mac-objc   Apple clang Objective-C (winemac.drv; DXMT's winemetal.so is C built with -ObjC)
#   mac-cxx    Apple clang++ with Wine's CXXFLAGS (lsteamclient.so); control: "-g -O2"
#   pe-wine    llvm-mingw aarch64, arm64ec and x86_64 DLLs with Wine's CROSSCFLAGS, __FILE__ in a critical section name
#   pe-arm64x  llvm-mingw -marm64x DLL (DXMT's PE side, FEX, the rebuilt CRT objects)
#   pe-gcc     mingw-w64 GCC x86_64 EXE with its symbol table (wz-steamprobe.exe) and stripped DLL (the forwarder)
#   metal      a .metal file fed on stdin (wz-n-dxmt-0001); control: the file named on the command line, with the maps
#   metallib   a metallib, as DXMT builds dxmt_command.metallib; control: the .air it was made from
#   mac-link   a cache reached through a symbolic link, compiled by its resolved path as meson does; control: the maps
#              of the link's spelling only
#   meson      a meson cross build like DXMT's (wz_cross_file_with_maps, *_FOR_BUILD) from sources outside the project;
#              control: DXMT's cross file as it is and no *_FOR_BUILD flags
# Needs runtime/n/build.sh's toolchain stage, Homebrew mingw-w64, meson, ninja, jq and the Metal toolchain. Writes only
# into its temporary folder (removed unless --keep); runs no Wine or game process.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
KEEP=0
while [ $# -gt 0 ]; do
    case "$1" in
        --keep) KEEP=1; shift ;;
        -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done
die() { echo "error: $*" >&2; exit 1; }

BUILD_CACHE="${WARZAG_CACHE:-$HOME/Library/Caches/warzag-build}"
LM="$BUILD_CACHE/work/n/toolchains/llvm-mingw-$(jq -r '.archives["llvm-mingw"].version' "$REPO/runtime/n/inputs.lock.json")-ucrt-macos-universal"
[ -x "$LM/bin/aarch64-w64-mingw32-clang" ] || die "no llvm-mingw at $LM (runtime/n/build.sh toolchain)"
BREW="$(brew --prefix)"
[ -x "$BREW/bin/x86_64-w64-mingw32-gcc" ] || die "brew install mingw-w64"
command -v meson >/dev/null && command -v ninja >/dev/null || die "brew install meson ninja"
xcrun -sdk macosx metal --version >/dev/null 2>&1 || die "no Metal compiler (xcodebuild -downloadComponent MetalToolchain)"
DXMT_CROSS="$BUILD_CACHE/work/n/repos/dxmt/build-arm64ec.txt"
[ -f "$DXMT_CROSS" ] || die "no DXMT checkout at $(dirname "$DXMT_CROSS") (runtime/n/fetch.sh)"

P="$(mktemp -d "$HOME/Library/Caches/warzag-path-probe.XXXXXX")"
cleanup() { if [ "$KEEP" = 1 ]; then echo "kept ${P/#$HOME/~}"; else rm -rf "$P"; fi; }
trap cleanup EXIT
# The probe's build cache and checkout, laid out like the real ones; the maps come from the build's own file.
CACHE="$P/cache"
ROOT="$P/checkout"
mkdir -p "$CACHE" "$ROOT"
# shellcheck source=runtime/n/path-maps.sh
. "$REPO/runtime/n/path-maps.sh"
read -r -a MAPS <<< "$PREFIX_MAPS"
export PATH="$LM/bin:$PATH" MACOSX_DEPLOYMENT_TARGET=15.0
unset CC CXX CFLAGS CXXFLAGS LDFLAGS CPPFLAGS OBJC OBJCFLAGS
CLANG=/usr/bin/clang
CLANGXX=/usr/bin/clang++

failed=0
results=()
scan() { # scan <dir>: forbidden-scan's personal findings (exit status ignored: judge reads the report)
    { python3 -I "$REPO/tools/release/forbidden-scan.py" --personal --path "$CACHE" --path "$ROOT" "$1" 2>&1 || true; } \
        | sed "s#$HOME#~#g"
}
judge() { # judge <probe> <out dir> <control dir> [note]
    local out control
    out="$(scan "$2")"
    control="$(scan "$3")"
    if [[ "$out" != *"forbidden-scan: clean"* ]]; then
        results+=("FAIL  $1: the build path is still there"); failed=1
        printf '%s\n' "$out" | sed 's/^/      /' | head -20
    elif [[ "$control" == *"forbidden-scan: clean"* ]]; then
        results+=("FAIL  $1: the control is clean too, so the check proves nothing"); failed=1
    else
        results+=("PASS  $1: no build path (control: $(grep -c '^PERSONAL' <<<"$control") file(s) named it)${4:+; $4}")
    fi
}
src() { # src <path> <text>: write a source file, creating its folder
    mkdir -p "$(dirname "$1")"
    printf '%s\n' "$2" > "$1"
}
C_PROBE='#include <assert.h>
#include <stdio.h>
const char *probe_where = __FILE__ ": probe_cs";
int probe(int x) { assert(x > 0); return printf("%s %d\n", probe_where, x); }'

# --- mac-c: nettle (in-tree, -ggdb3) and Wine's unix side (out-of-tree), -oso_prefix, then strip -S ------------------
mac_c() { # mac_c <out dir> <cflags...>; uses OSO when set
    local out="$1"; shift
    mkdir -p "$out"
    (cd "$CACHE/work/n/deps-build/nettle" && "$CLANG" -arch arm64 -O2 -ggdb3 "$@" -c aes-probe.c -o aes-probe.o)
    "$CLANG" -arch arm64 -O2 "$@" -c "$CACHE/work/n/src/wine-11.19/dlls/ntdll/unix/probe.c" -o "$out/unix-probe.o"
    "$CLANG" -arch arm64 -dynamiclib -install_name @rpath/libprobe.dylib -o "$out/libprobe.dylib" \
        "$CACHE/work/n/deps-build/nettle/aes-probe.o" "$out/unix-probe.o" ${OSO:+"$OSO"}
    rm -f "$out/unix-probe.o" "$CACHE/work/n/deps-build/nettle/aes-probe.o"
}
src "$CACHE/work/n/deps-build/nettle/aes-probe.c" "$C_PROBE"
src "$CACHE/work/n/src/wine-11.19/dlls/ntdll/unix/probe.c" "${C_PROBE//probe/unix_probe}"
OSO="$OSO_PREFIX" mac_c "$P/out/mac-c" "${MAPS[@]}"
OSO="" mac_c "$P/control/mac-c"
oso="$(nm -ap "$P/out/mac-c/libprobe.dylib" | awk '$5 == "OSO" {print $6}' | tr '\n' ' ')"
cp "$P/out/mac-c/libprobe.dylib" "$P/out/mac-c/libprobe-stripped.dylib"
/usr/bin/strip -S "$P/out/mac-c/libprobe-stripped.dylib"
stabs="$(nm -ap "$P/out/mac-c/libprobe-stripped.dylib" | grep -cE ' (SO|OSO) ' || true)"
judge mac-c "$P/out/mac-c" "$P/control/mac-c" "debug map object paths: ${oso% }; after strip -S: $stabs stabs"
[ "$stabs" = 0 ] || { results+=("FAIL  mac-c: strip -S left $stabs debug-map entries"); failed=1; }

# --- mac-objc ------------------------------------------------------------------------------------------------------
OBJC_PROBE='#import <Foundation/Foundation.h>
#include <assert.h>
void probe_objc(int x) { assert(x > 0); NSLog(@"%s: %d", __FILE__, x); }'
src "$CACHE/work/n/src/wine-11.19/dlls/winemac.drv/probe.m" "$OBJC_PROBE"
mkdir -p "$P/out/mac-objc" "$P/control/mac-objc"
"$CLANG" -arch arm64 -O2 "${MAPS[@]}" -dynamiclib -install_name @rpath/probe.so -framework Foundation "$OSO_PREFIX" \
    -o "$P/out/mac-objc/probe.so" "$CACHE/work/n/src/wine-11.19/dlls/winemac.drv/probe.m"
"$CLANG" -arch arm64 -O2 -dynamiclib -install_name @rpath/probe.so -framework Foundation \
    -o "$P/control/mac-objc/probe.so" "$CACHE/work/n/src/wine-11.19/dlls/winemac.drv/probe.m"
judge mac-objc "$P/out/mac-objc" "$P/control/mac-objc"

# --- mac-cxx: lsteamclient.so ----------------------------------------------------------------------------------------
CXX_PROBE='#include <cassert>
#include <cstdio>
extern "C" int probe_cxx(int x) { assert(x > 0); return std::printf("%s %d\n", __FILE__, x); }'
src "$CACHE/work/n/src/wine-11.19/dlls/lsteamclient/probe.cpp" "$CXX_PROBE"
mkdir -p "$P/out/mac-cxx" "$P/control/mac-cxx"
(cd "$P/out/mac-cxx" && "$CLANGXX" -arch arm64 -O2 "${MAPS[@]}" -c "$CACHE/work/n/src/wine-11.19/dlls/lsteamclient/probe.cpp" \
    -o probe.o && "$CLANG" -arch arm64 -dynamiclib -install_name @rpath/lsteamclient-probe.so -o lsteamclient-probe.so \
    probe.o -lc++ "$OSO_PREFIX" && rm probe.o)
(cd "$P/control/mac-cxx" && "$CLANGXX" -arch arm64 -g -O2 -c "$CACHE/work/n/src/wine-11.19/dlls/lsteamclient/probe.cpp" \
    -o probe.o && "$CLANG" -arch arm64 -dynamiclib -install_name @rpath/lsteamclient-probe.so -o lsteamclient-probe.so \
    probe.o -lc++)
stabs="$(nm -ap "$P/out/mac-cxx/lsteamclient-probe.so" | grep -cE ' (SO|OSO) ' || true)"
judge mac-cxx "$P/out/mac-cxx" "$P/control/mac-cxx" "$stabs debug-map entries"

# --- pe-wine: Wine's PE side (CROSSCFLAGS) ------------------------------------------------------------------------
PE_PROBE='#include <assert.h>
#include <windows.h>
static const char *cs_name = __FILE__ ": probe_section";
__declspec(dllexport) int probe_pe(int x) { assert(x > 0); return lstrlenA(cs_name) + x; }'
src "$CACHE/work/n/src/wine-11.19/dlls/kernelbase/probe.c" "$PE_PROBE"
mkdir -p "$P/out/pe-wine" "$P/control/pe-wine"
for arch in aarch64 arm64ec x86_64; do
    "$arch-w64-mingw32-clang" -O2 -g0 "${MAPS[@]}" -shared -o "$P/out/pe-wine/probe-$arch.dll" \
        "$CACHE/work/n/src/wine-11.19/dlls/kernelbase/probe.c"
    "$arch-w64-mingw32-clang" -O2 -g0 -shared -o "$P/control/pe-wine/probe-$arch.dll" \
        "$CACHE/work/n/src/wine-11.19/dlls/kernelbase/probe.c"
done
judge pe-wine "$P/out/pe-wine" "$P/control/pe-wine"

# --- pe-arm64x: DXMT, FEX, CRT ----------------------------------------------------------------------------------------
src "$CACHE/work/n/src/dxmt/src/probe/probe.c" "$PE_PROBE"
mkdir -p "$P/out/pe-arm64x" "$P/control/pe-arm64x"
arm64ec-w64-mingw32-clang -marm64x -O2 "${MAPS[@]}" -shared -o "$P/out/pe-arm64x/probe.dll" \
    "$CACHE/work/n/src/dxmt/src/probe/probe.c"
arm64ec-w64-mingw32-clang -marm64x -O2 -shared -o "$P/control/pe-arm64x/probe.dll" "$CACHE/work/n/src/dxmt/src/probe/probe.c"
kind="$(python3 -I "$REPO/qa/n/pe-arch.py" "$P/out/pe-arm64x/probe.dll" | cut -f1)"
judge pe-arm64x "$P/out/pe-arm64x" "$P/control/pe-arm64x" "image kind: $kind"

# --- pe-gcc: the bridge's x86 programs ------------------------------------------------------------------------------
src "$ROOT/bridge/steamprobe/probe.c" '#include <assert.h>
#include <stdio.h>
int main(int argc, char **argv) { (void)argv; assert(argc > 0); printf("%s\n", __FILE__); return 0; }'
src "$ROOT/bridge/forwarders/probe.c" '#include <windows.h>
const char *probe_where = __FILE__;
BOOL WINAPI DllMain(HINSTANCE h, DWORD r, LPVOID p) { (void)h; (void)r; (void)p; return probe_where != 0; }'
mkdir -p "$P/out/pe-gcc" "$P/control/pe-gcc"
for out in out control; do
    flags=()
    [ "$out" = control ] || flags=("${MAPS[@]}")
    "$BREW/bin/x86_64-w64-mingw32-gcc" -std=gnu17 -O2 ${flags[@]+"${flags[@]}"} -mconsole -o "$P/$out/pe-gcc/probe.exe" \
        "$ROOT/bridge/steamprobe/probe.c" -static-libgcc
    "$BREW/bin/x86_64-w64-mingw32-gcc" -std=gnu17 -O2 ${flags[@]+"${flags[@]}"} -shared -s \
        -o "$P/$out/pe-gcc/probe.dll" "$ROOT/bridge/forwarders/probe.c"
done
judge pe-gcc "$P/out/pe-gcc" "$P/control/pe-gcc"

# --- metal: airconv's shaders (wz-n-dxmt-0001) -------------------------------------------------------------------
src "$CACHE/work/n/src/dxmt/src/airconv/shaders/probe.metal" '#include <metal_stdlib>
using namespace metal;
kernel void probe_kernel(device uint *out [[buffer(0)]], uint id [[thread_position_in_grid]]) { out[id] = absdiff(id, 7u); }'
mkdir -p "$P/out/metal" "$P/control/metal" "$CACHE/work/n/src/dxmt/build"
(cd "$CACHE/work/n/src/dxmt/build" \
    && xcrun -sdk macosx metal -x metal -o "$P/out/metal/probe.air" -c - -std=metal3.1 --target=air64-apple-macos14.0 \
        "${MAPS[@]}" < ../src/airconv/shaders/probe.metal \
    && xcrun -sdk macosx metal -o "$P/control/metal/probe.air" -c ../src/airconv/shaders/probe.metal -std=metal3.1 \
        --target=air64-apple-macos14.0 "${MAPS[@]}")
judge metal "$P/out/metal" "$P/control/metal"

# --- metallib: dxmt_command.metal (DXMT's metalir_generator, then metallib_generator) --------------------------------
src "$CACHE/work/n/src/dxmt/src/dxmt/probe_command.metal" '#include <metal_stdlib>
using namespace metal;
kernel void probe_command(device uint *out [[buffer(0)]], uint id [[thread_position_in_grid]]) { out[id] = id * 3u; }'
mkdir -p "$P/out/metallib" "$P/control/metallib"
(cd "$CACHE/work/n/src/dxmt/build" \
    && xcrun -sdk macosx metal -o "$P/control/metallib/probe_command.air" -c ../src/dxmt/probe_command.metal \
    && xcrun -sdk macosx metallib -o "$P/out/metallib/probe_command.metallib" "$P/control/metallib/probe_command.air")
judge metallib "$P/out/metallib" "$P/control/metallib" "the .air names its source file, the metallib does not"

# --- mac-link: a cache reached through a symbolic link ----------------------------------------------------------------
mkdir -p "$P/link-target"
ln -s link-target "$P/link-cache"
src "$P/link-target/work/n/src/dxmt/src/winemetal/unix/probe.c" "$C_PROBE"
link_maps="$(CACHE="$P/link-cache"; . "$REPO/runtime/n/path-maps.sh"; echo "$PREFIX_MAPS")"
read -r -a LINK_MAPS <<< "$link_maps"
mkdir -p "$P/out/mac-link" "$P/control/mac-link"
"$CLANG" -arch arm64 -O2 "${LINK_MAPS[@]}" -dynamiclib -install_name @rpath/probe.so -o "$P/out/mac-link/probe.so" \
    "$P/link-target/work/n/src/dxmt/src/winemetal/unix/probe.c"
"$CLANG" -arch arm64 -O2 "-ffile-prefix-map=$P/link-cache=/warzag-build" -dynamiclib -install_name @rpath/probe.so \
    -o "$P/control/mac-link/probe.so" "$P/link-target/work/n/src/dxmt/src/winemetal/unix/probe.c"
judge mac-link "$P/out/mac-link" "$P/control/mac-link" "$(grep -o -- '-ffile-prefix-map=[^ ]*=/warzag-build' <<<"$link_maps" \
    | wc -l | tr -d ' ') spellings of the cache mapped"

# --- meson: DXMT's cross build ------------------------------------------------------------------------------------
M="$CACHE/work/n/src/meson-probe"
EXT="$CACHE/work/n/wine-sdk/probe-src"
src "$M/meson.build" "project('probe', ['c', 'cpp'])
ext = get_option('ext')
shared_library('probe_pe', ext / 'pe.c')
shared_library('probe_mac', ext / 'mac.c', native: true, c_args: ['-ObjC'], link_args: ['-framework', 'Foundation'])"
src "$M/meson.options" "option('ext', type: 'string', value: '')"
src "$EXT/pe.c" "$PE_PROBE"
src "$EXT/mac.c" "$OBJC_PROBE"
cp "$DXMT_CROSS" "$P/dxmt-cross-original.txt"
wz_cross_file_with_maps "$DXMT_CROSS" "$P/dxmt-cross.txt"
(cd "$M" && CC="$CLANG" CFLAGS_FOR_BUILD="$PREFIX_MAPS" LDFLAGS_FOR_BUILD="$OSO_PREFIX" \
    meson setup build-out --cross-file "$P/dxmt-cross.txt" -Dext="$EXT" --buildtype release >"$P/meson-out.log" 2>&1 \
    && ninja -C build-out >>"$P/meson-out.log" 2>&1) || { sed "s#$HOME#~#g" "$P/meson-out.log" | tail -20; die "meson probe failed"; }
(cd "$M" && CC="$CLANG" meson setup build-control --cross-file "$P/dxmt-cross-original.txt" -Dext="$EXT" \
    --buildtype release >"$P/meson-control.log" 2>&1 && ninja -C build-control >>"$P/meson-control.log" 2>&1) \
    || { sed "s#$HOME#~#g" "$P/meson-control.log" | tail -20; die "meson control failed"; }
mkdir -p "$P/out/meson" "$P/control/meson"
cp "$M"/build-out/*.dll "$M"/build-out/*.dylib "$P/out/meson/"
cp "$M"/build-control/*.dll "$M"/build-control/*.dylib "$P/control/meson/"
arm64x="$(grep -c -- '-marm64x' "$M/build-out/compile_commands.json" || true)"
judge meson "$P/out/meson" "$P/control/meson" "-marm64x kept in $arm64x compile command(s)"
[ "$arm64x" -ge 1 ] || { results+=("FAIL  meson: the PE compile lost DXMT's -marm64x"); failed=1; }

echo
printf '%s\n' "${results[@]}"
[ $failed = 0 ] && echo "path maps: every probe passed" || echo "path maps: FAILED"
exit $failed
