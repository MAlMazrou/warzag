#!/bin/bash
# Check runtime/n/build.sh's release flags (runtime/n/path-maps.sh) on real Wine and DXMT code without a full engine
# build, in a scratch copy of the build cache, with build.sh's own functions:
#   1. wine_configure, then make of the modules that name the build cache without the maps: ntdll (with the x86-64
#      code inside the ARM64EC module), kernelbase, rpcrt4 and oleaut32 (arm64ec_x64 thunks, widl output), conhost,
#      winemac.drv (Objective-C), lsteamclient (C++ unix side), the loader and wineserver;
#   2. stage_dxmt: neutron's DXMT series and Warzag's DXMT patches (wz-n-dxmt-*), the cross file with the maps,
#      *_FOR_BUILD;
# then tools/release/forbidden-scan.py --personal over every output: nothing may name the scratch cache, the real
# cache, the checkout, the home folder or the user name.
#
#   qa/n/release-flags-check.sh [--keep] [--jobs N]
#
# Needs a build cache (WARZAG_CACHE, default ~/Library/Caches/warzag-build) where runtime/n/build.sh has run the
# toolchain, deps, wine-src, wine and llvm stages, and runtime/n/fetch.sh's DXMT checkout. The inputs are cloned
# (cp -c) into a temporary folder under ~/Library/Caches, so paths name the home folder as the real ones do; the real
# cache is not written. Builds only; runs no Wine or game process.
set -euo pipefail

# WARZAG_ROOT (the checkout) lets it run from a copy of this script, as build.sh does: bash reads a script while it
# runs, so editing the checked-out file under a running check would be unsafe.
REPO="${WARZAG_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
KEEP=0
JOBS=4
while [ $# -gt 0 ]; do
    case "$1" in
        --keep) KEEP=1; shift ;;
        --jobs) JOBS="$2"; shift 2 ;;
        -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done
die() { echo "error: $*" >&2; exit 1; }

REAL="${WARZAG_CACHE:-$HOME/Library/Caches/warzag-build}"
REAL="${REAL%/}"
WINE_VERSION="$(jq -r '.archives.wine.version' "$REPO/runtime/n/inputs.lock.json")"
LMV="llvm-mingw-$(jq -r '.archives["llvm-mingw"].version' "$REPO/runtime/n/inputs.lock.json")-ucrt-macos-universal"
for need in "src/wine-$WINE_VERSION/configure|runtime/n/build.sh wine-src" "deps/lib/libgnutls.30.dylib|runtime/n/build.sh deps" \
         "toolchains/$LMV/bin/aarch64-w64-mingw32-clang|runtime/n/build.sh toolchain" \
         "toolchains/llvm-darwin-arm64/lib/libLLVMCore.a|runtime/n/build.sh llvm" \
         "wine-sdk/bin/winebuild|runtime/n/build.sh wine" "repos/dxmt/build-arm64ec.txt|runtime/n/fetch.sh"; do
    [ -e "$REAL/work/n/${need%%|*}" ] || die "no work/n/${need%%|*} in the build cache: run ${need##*|} first"
done
common="$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
MAIN="$REPO"
[ -z "$common" ] || MAIN="$(cd "$common/.." && pwd)"

P="$(mktemp -d "$HOME/Library/Caches/warzag-release-check.XXXXXX")"
cleanup() { if [ "$KEEP" = 1 ]; then echo "kept ${P/#$HOME/~}"; else rm -rf "$P"; fi; }
trap cleanup EXIT
shown() { sed "s#$HOME#~#g"; }

echo "==> copy the inputs (cp -c) into ${P/#$HOME/~}/cache"
N_COPY="$P/cache/work/n"
mkdir -p "$N_COPY/src" "$N_COPY/toolchains" "$N_COPY/repos/dxmt"
cp -c -R "$REAL/work/n/src/wine-$WINE_VERSION" "$N_COPY/src/"
cp -c -R "$REAL/work/n/deps" "$REAL/work/n/wine-sdk" "$N_COPY/"
cp -c -R "$REAL/work/n/toolchains/$LMV" "$REAL/work/n/toolchains/llvm-darwin-arm64" "$N_COPY/toolchains/"
# The DXMT checkout without its git metadata: build.sh's `git apply` then patches the files as patch(1) would.
(cd "$REAL/work/n/repos/dxmt" && tar -cf - --exclude .git .) | tar -xf - -C "$N_COPY/repos/dxmt"

# build.sh's definitions and checks, for the scratch cache, without its stage loop.
sed '/^for s in "\${STAGES\[@\]}"; do$/,$d' "$REPO/runtime/n/build.sh" > "$P/build-definitions.sh"
grep -q '^wine_configure()' "$P/build-definitions.sh" && grep -q '^stage_dxmt()' "$P/build-definitions.sh" \
    && ! grep -q '^for s in' "$P/build-definitions.sh" || die "runtime/n/build.sh no longer has the expected layout"
export WARZAG_CACHE="$P/cache" WARZAG_ROOT="$REPO"
set -- --jobs "$JOBS"
# shellcheck disable=SC1091
. "$P/build-definitions.sh"
copy_repo() { rm -rf "$2"; cp -R "$REPOS/$1" "$2"; }   # the copy above (no git metadata)
# wine_configure starts with rm -rf "$B": everything must point into the scratch copy.
[ "$CACHE" = "$P/cache" ] && [ "$B" = "$P/cache/work/n/wine-build" ] && [ "$WORK" = "$P/cache/work/n" ] \
    || die "build.sh did not take the scratch cache (WARZAG_CACHE)"
echo "maps: $PREFIX_MAPS" | shown

results=()
failed=0
pass() { results+=("PASS  $1"); }
fail() { results+=("FAIL  $1"); failed=1; }

echo "==> wine_configure (runtime/n/build.sh)"
wine_configure
pass "Wine's configure carried the maps into CFLAGS, CXXFLAGS, the PE flags (arm64ec, aarch64, x86_64) and LDFLAGS"

echo "==> make (modules that named the cache before the maps; log: work/n/logs/release-check-make.log)"
for f in "$DEPS"/lib/libfreetype*.dylib; do ln -sf "$f" "$B/$(basename "$f")"; done
targets=(dlls/ntdll/all dlls/kernelbase/all dlls/rpcrt4/all dlls/oleaut32/all programs/conhost/all
         dlls/winemac.drv/all dlls/lsteamclient/all loader/wine server/wineserver)
(cd "$B" && make -j"$JOBS" "${targets[@]}" > "$LOGS/release-check-make.log" 2>&1) \
    || { tail -40 "$LOGS/release-check-make.log" | shown; die "make failed"; }
if grep -Eq 'x86_64-w64-mingw32-gcc .*signal_x86_64\.c' "$LOGS/release-check-make.log"; then
    pass "ntdll's x86-64 code (arm64ec_x64) was compiled with x86_64_CFLAGS"
else
    fail "ntdll's signal_x86_64.c was not compiled by the x86-64 compiler (the arm64ec_x64 path was not exercised)"
fi

echo "==> stage_dxmt (runtime/n/build.sh)"
stage_dxmt
if grep -q -- 'metal -x metal -o .* -c -' "$SRC/dxmt/build-arm64ec/build.ninja"; then
    pass "airconv's shaders are compiled from stdin (wz-n-dxmt-0001)"
else
    fail "airconv's shaders are not compiled from stdin"
fi

O="$P/outputs"
mkdir -p "$O/wine" "$O/dxmt"
for f in dlls/ntdll/aarch64-windows/ntdll.dll dlls/ntdll/ntdll.so dlls/kernelbase/aarch64-windows/kernelbase.dll \
         dlls/rpcrt4/aarch64-windows/rpcrt4.dll dlls/oleaut32/aarch64-windows/oleaut32.dll \
         programs/conhost/aarch64-windows/conhost.exe dlls/winemac.drv/winemac.so \
         dlls/winemac.drv/aarch64-windows/winemac.drv dlls/lsteamclient/lsteamclient.so \
         dlls/lsteamclient/aarch64-windows/lsteamclient.dll loader/wine server/wineserver; do
    cp "$B/$f" "$O/wine/${f//\//_}"
done
cp -R "$WORK/dxmt-install/." "$O/dxmt/"
count="$(find "$O" -type f | wc -l | tr -d ' ')"

echo "==> scan $count outputs"
scan="$(python3 -I "$REPO/tools/release/forbidden-scan.py" --personal --path "$P/cache" --path "$REAL" \
    --path "$REPO" --path "$MAIN" "$O" 2>&1 || true)"
printf '%s\n' "$scan" | shown | tail -20
if [[ "$scan" == *"forbidden-scan: clean"* ]]; then
    pass "none of the $count Wine and DXMT outputs names the build machine"
else
    fail "outputs name the build machine (above)"
fi

# Control: the same files of the real stage, when it was built before the maps, name the real cache.
stage="$REAL/work/n/stage"
if [ -d "$stage" ]; then
    mkdir -p "$P/control"
    for f in lib/wine/aarch64-windows/ntdll.dll lib/wine/aarch64-windows/kernelbase.dll \
             lib/wine/aarch64-windows/rpcrt4.dll lib/wine/aarch64-windows/conhost.exe \
             lib/wine/aarch64-unix/lsteamclient.so renderers/dxmt/aarch64-unix/winemetal.so; do
        [ ! -f "$stage/$f" ] || cp "$stage/$f" "$P/control/"
    done
    named="$(python3 -I "$REPO/tools/release/forbidden-scan.py" --personal --path "$REAL" "$P/control" 2>&1 \
        | grep -c '^PERSONAL' || true)"
    results+=("note  control: $named of $(ls "$P/control" | wc -l | tr -d ' ') of the same files in the real stage name the build machine (built before the maps: all; after a release build: none)")
fi

echo
printf '%s\n' "${results[@]}"
[ $failed = 0 ] && echo "release flags: clean" || echo "release flags: FAILED"
exit $failed
