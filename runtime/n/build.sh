#!/bin/bash
# Build Warzag's engine: native arm64 Wine 11.19 with ARM64EC (ARM64X) Windows DLLs, FEX as the in-process
# x86-64 emulator (libarm64ecfex.dll in the xtajit64 role), DXMT (D3D10/11/12 -> Metal) for ARM64EC with its arm64
# winemetal.so, and Proton's lsteamclient bridging to the user's unmodified Mac Steam. Nothing runs under Rosetta.
# The recipe follows neutron's build.sh (runtime/n/inputs.lock.json pins the same versions; neutron's patch series is
# vendored in runtime/n/patches) with Warzag's app-bundle layout and Warzag's own patches on top. The CRT rebuild and
# the LLVM, FEX and DXMT configurations are adapted from neutron's build.sh at 0ac2574d
# (https://github.com/lixsldotnet/neutron, LGPL-2.1-or-later).
#
#   runtime/n/build.sh [--jobs N] [--redo] [--with-mono] [stage ...]
#   stages (default: all, in order): toolchain deps wine-src wine llvm fex dxmt bridge install
#     toolchain  llvm-mingw 20260908 + winnt.h TSD patch + CRT startup objects rebuilt from mingw-w64 9f55f4a
#     deps       arm64 gmp/nettle/gnutls/freetype (runtime/inputs.lock.json) and SDL3 + sdl2-compat
#     wine-src   Wine 11.19 + neutron's series + Proton lsteamclient (in-tree) + Warzag's patches, autoreconf
#     wine       configure (arm64ec,aarch64; bindir=/MacOS libdir=/lib datadir=/share) and make
#     llvm       LLVM 15.0.7 libraries for DXMT's airconv (no targets, no assertions)
#     fex        FEX-2610: ARM64EC libarm64ecfex.dll + macOS unixlib libarm64ecfex.so
#     dxmt       DXMT e94c312f (ARM64X PE + aarch64 winemetal.so), against a Wine SDK install
#     bridge     steamclient64 forwarder, steam.exe (arm64), wz-steamprobe.exe (x86_64, like a game)
#     install    assemble $WARZAG_CACHE/work/n/stage (= Contents/ of Warzag.app; --with-mono adds Wine Mono), which
#                runtime/n/make-host.sh bundles. Fails if the stage names the cache, the checkout, the home folder or
#                the user name.
#     make       not in the default list: an incremental make in the configured Wine tree (clears the install marker)
#
# A finished stage leaves work/n/.done-<stage> and is skipped next time; --redo (or deleting the marker) rebuilds the
# named stages, and running a stage clears the markers of the stages that use its output (dependents() below).
# --jobs sets the parallel jobs (default 6). Inputs come from runtime/n/fetch.sh; nothing is written into the
# repository. Every compiler gets the path maps of
# runtime/n/path-maps.sh; a release build is a clean run of every stage.
set -euo pipefail

# WARZAG_ROOT lets a long build run from a copy of this script (bash reads a script while it runs, so editing the
# checked-out file under a running build would be unsafe).
ROOT="${WARZAG_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
N="$ROOT/runtime/n"
LOCK="$N/inputs.lock.json"
PATCHES="$N/patches"
CACHE="${WARZAG_CACHE:-$HOME/Library/Caches/warzag-build}"
CACHE="${CACHE%/}"
WORK="$CACHE/work/n"
DL="$WORK/downloads"
REPOS="$WORK/repos"
SRC="$WORK/src"
T="$WORK/toolchains"
DEPS="$WORK/deps"
STAGE="$WORK/stage"
LOGS="$WORK/logs"
JOBS=6
REDO=0
WITH_MONO=0
MIN_MACOS="15.0"

WINE_VERSION="$(jq -r '.archives.wine.version' "$LOCK")"
LLVM_MINGW_VERSION="$(jq -r '.archives["llvm-mingw"].version' "$LOCK")"
LLVM_MINGW_DIR="llvm-mingw-$LLVM_MINGW_VERSION-ucrt-macos-universal"
LM="$T/$LLVM_MINGW_DIR"
W="$SRC/wine-$WINE_VERSION"
B="$WORK/wine-build"
SDK="$WORK/wine-sdk"
LLVM15="$T/llvm-darwin-arm64"

# neutron: the TEB lives in a pthread TSD slot (macOS clears x18); Wine publishes the slot offset next to
# KUSER_SHARED_DATA, which has to sit above the 4 GB __PAGEZERO of arm64 macOS binaries.
NATIVE_DEFS="-DWINE_TEB_IN_TSD -DWINE_USER_SHARED_DATA_VA=0x7ffffdfe0000ull"

STAGES=()
while [ $# -gt 0 ]; do
    case "$1" in
        --jobs) JOBS="$2"; shift 2 ;;
        --redo) REDO=1; shift ;;
        --with-mono) WITH_MONO=1; shift ;;
        -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
        -*) echo "unknown option: $1" >&2; exit 2 ;;
        *) STAGES+=("$1"); shift ;;
    esac
done
ALL_STAGES=(toolchain deps wine-src wine llvm fex dxmt bridge install)
[ ${#STAGES[@]} -eq 0 ] && STAGES=("${ALL_STAGES[@]}")

log() { printf '\n==> [%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { echo "error: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required ($2)"; }

[ "$(uname -m)" = arm64 ] || die "the engine builds on Apple silicon only"
need jq "brew install jq"; need cmake "brew install cmake"; need ninja "brew install ninja"
need meson "brew install meson"; need autoreconf "brew install autoconf automake"; need git "Xcode"
need x86_64-w64-mingw32-gcc "brew install mingw-w64"
xcrun -sdk macosx metal --version >/dev/null 2>&1 \
    || die "no Metal compiler: full Xcode plus 'xcodebuild -downloadComponent MetalToolchain'"

BREW="$(brew --prefix)"
export PATH="$LM/bin:$BREW/opt/bison/bin:$BREW/opt/flex/bin:$PATH"
# llvm-mingw's bin (first in PATH) has a plain clang without the macOS SDK: Mac code is always built with Apple's.
HOST_CC=/usr/bin/clang
HOST_CXX=/usr/bin/clang++
HOST_CMAKE=(-DCMAKE_C_COMPILER="$HOST_CC" -DCMAKE_CXX_COMPILER="$HOST_CXX" -DCMAKE_OBJC_COMPILER="$HOST_CC")
# llvm-mingw also has x86_64-w64-mingw32-gcc (a clang wrapper). The x86_64 programs (the forwarder,
# wz-steamprobe.exe) are built with Homebrew's mingw-w64 GCC (runtime/toolchain.lock.json).
GCC_MINGW="$BREW/bin"
[ -x "$GCC_MINGW/x86_64-w64-mingw32-gcc" ] || die "brew install mingw-w64"
export MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS"
# Nothing from Homebrew may leak into the engine: pkg-config only ever sees our own arm64 deps.
export PKG_CONFIG_LIBDIR="$DEPS/lib/pkgconfig"
export PKG_CONFIG_PATH=""
unset CC CXX CFLAGS CXXFLAGS LDFLAGS CPPFLAGS OBJC OBJCFLAGS
mkdir -p "$WORK" "$SRC" "$T" "$LOGS"
# PREFIX_MAPS (every compiler: the cache becomes /warzag-build, the checkout /warzag, in both spellings when a
# symbolic link is in the way, so the cache must exist first), OSO_PREFIX (every Mach-O link) and
# wz_cross_file_with_maps (DXMT's meson cross file).
# shellcheck source=runtime/n/path-maps.sh
. "$N/path-maps.sh"

archive() { echo "$DL/$1/$(jq -r --arg n "$1" '.archives[$n].url' "$LOCK" | sed 's#.*/##')"; }
shared_archive() { echo "$CACHE/downloads/$1/$(jq -r --arg n "$1" '.archives[$n].url' "$ROOT/runtime/inputs.lock.json" | sed 's#.*/##')"; }
sha_ok() { echo "$2  $1" | shasum -a 256 -c --status; }
verified() {  # verified <name>: path of an archive of runtime/n/inputs.lock.json, after checking its SHA-256 again
    local f sha
    f="$(archive "$1")"; sha="$(jq -r --arg n "$1" '.archives[$n].sha256' "$LOCK")"
    [ -f "$f" ] && sha_ok "$f" "$sha" || die "$1 missing or corrupt: run runtime/n/fetch.sh"
    echo "$f"
}
shared_verified() {  # the same for runtime/inputs.lock.json
    local f sha
    f="$(shared_archive "$1")"; sha="$(jq -r --arg n "$1" '.archives[$n].sha256' "$ROOT/runtime/inputs.lock.json")"
    [ -f "$f" ] && sha_ok "$f" "$sha" || die "$1 missing or corrupt: run runtime/n/fetch.sh"
    echo "$f"
}
repo() {  # repo <name>: the verified checkout of a git input
    local d="$REPOS/$1" c
    c="$(jq -r --arg n "$1" '.git[$n].commit' "$LOCK")"
    [ "$(git -C "$d" rev-parse HEAD 2>/dev/null)" = "$c" ] || die "$1 checkout is not at $c: run runtime/n/fetch.sh"
    echo "$d"
}
# The stages that use a stage's output directly. Running a stage clears their done markers, so a later run without
# --redo rebuilds them instead of shipping stale results (after "--redo wine-src" with new patches, a plain run must
# not keep the old Wine build and stage).
dependents() {
    case "$1" in
        toolchain) echo "wine fex dxmt bridge" ;;
        deps) echo "wine install" ;;
        wine-src) echo "wine bridge" ;;
        wine) echo "dxmt install" ;;
        llvm) echo "dxmt" ;;
        fex|dxmt|bridge) echo "install" ;;
    esac
}

# run_stage <name>: run a stage unless it finished before (--redo runs it again).
run_stage() {
    local name="$1" marker="$WORK/.done-$1" start end d
    if [ -f "$marker" ] && [ "$REDO" = 0 ]; then
        echo "--- $name: done before ($(cat "$marker")), skipped (use --redo to rebuild)"
        return 0
    fi
    rm -f "$marker"
    for d in $(dependents "$name"); do rm -f "$WORK/.done-$d"; done
    start="$(date +%s)"
    log "stage $name"
    "stage_${name//-/_}"
    end="$(date +%s)"
    echo "$(date '+%Y-%m-%d %H:%M:%S'), $((end - start)) s" > "$marker"
    log "stage $name done in $((end - start)) s"
}

# ---------------------------------------------------------------------------------------------
# toolchain: llvm-mingw with NtCurrentTeb from the TSD slot (neutron's recipe)
stage_toolchain() {
    rm -rf "$LM"
    tar -xJf "$(verified llvm-mingw)" -C "$T"
    (cd "$LM" && patch -p1 -s < "$PATCHES/llvm-mingw/0001-ntcurrentteb-tsd.patch")

    # The prebuilt CRT startup objects read the TEB through x18: rebuild them with the patched header, as ARM64X
    # like llvm-mingw does (--enable-arm64x, cfguard), from the mingw-w64 commit this llvm-mingw was built from.
    local mw crt c L
    mw="$(repo mingw-w64)"
    crt="$WORK/crt-objs"
    rm -rf "$crt"; mkdir -p "$crt"
    # (These objects go into every PE file llvm-mingw links: steam.exe, FEX, DXMT; hence the path maps.)
    local maps
    read -r -a maps <<< "$PREFIX_MAPS"
    local cflags=(-marm64x -O2 -pipe -std=gnu99 -fno-builtin -D_CRTBLD -D_WIN32_WINNT=0x0f00 -D__MSVCRT_VERSION__=0x600
                  -D__USE_MINGW_ANSI_STDIO=0 -mguard=cf -DHAS_CFGUARD -I"$mw/mingw-w64-crt/include" "${maps[@]}")
    c="$mw/mingw-w64-crt/crt"
    aarch64-w64-mingw32-clang "${cflags[@]}" -D_SYSCRT=1 -c "$c/crtexe.c"  -o "$crt/crt1.o"
    aarch64-w64-mingw32-clang "${cflags[@]}" -D_SYSCRT=1 -c "$c/ucrtexe.c" -o "$crt/crt1u.o"
    aarch64-w64-mingw32-clang "${cflags[@]}" -D_SYSCRT=1 -c "$c/crtdll.c"  -o "$crt/dllcrt1.o"
    aarch64-w64-mingw32-clang "${cflags[@]}" -c "$c/tlsdtor.c" -o "$crt/libarm64_libmingw32_a-tlsdtor.o"
    L="$LM/aarch64-w64-mingw32/lib"
    cp "$crt/crt1.o" "$L/crt1.o";       cp "$crt/crt1.o" "$L/crt2.o"
    cp "$crt/crt1u.o" "$L/crt1u.o";     cp "$crt/crt1u.o" "$L/crt2u.o"
    cp "$crt/dllcrt1.o" "$L/dllcrt1.o"; cp "$crt/dllcrt1.o" "$L/dllcrt2.o"
    (cd "$crt" && "$LM/bin/llvm-ar" r "$L/libmingw32.a" libarm64_libmingw32_a-tlsdtor.o)
    aarch64-w64-mingw32-clang --version | head -1
    grep -q 'tpidrro_el0' "$LM/generic-w64-mingw32/include/winnt.h" || die "winnt.h is not patched"
}

# ---------------------------------------------------------------------------------------------
# deps: the dylibs Wine dlopens, built for arm64 and macOS 15 from pinned sources (@rpath install names)
# The autotools builds read these variables; CMake (freetype, SDL3, sdl2-compat) starts its CMAKE_<LANG>_FLAGS and
# linker flags from them on a first configure.
arm64_env() {
    export CC="$HOST_CC -arch arm64" CXX="$HOST_CXX -arch arm64" OBJC="$HOST_CC -arch arm64"
    export CFLAGS="-O2 -mmacosx-version-min=$MIN_MACOS $PREFIX_MAPS"
    export CXXFLAGS="-O2 -mmacosx-version-min=$MIN_MACOS $PREFIX_MAPS"
    export OBJCFLAGS="$CFLAGS" CPPFLAGS="-I$DEPS/include"
    export LDFLAGS="-L$DEPS/lib -Wl,-headerpad_max_install_names -mmacosx-version-min=$MIN_MACOS $OSO_PREFIX"
}

extract() {  # extract <archive> <dest-dir>: a fresh copy
    rm -rf "$2"; mkdir -p "$2"
    tar -xf "$1" -C "$2" --strip-components 1
}

stage_deps() {
    local b="$WORK/deps-build" cx="$WORK/crossover-sources" host=aarch64-apple-darwin
    rm -rf "$DEPS" "$b"; mkdir -p "$DEPS/lib/pkgconfig" "$b"
    (
    arm64_env
    log "crossover-sources: gmp, gnutls, freetype trees"
    if [ ! -d "$cx/sources/gnutls" ]; then
        rm -rf "$cx"; mkdir -p "$cx"
        tar -xzf "$(shared_verified crossover-sources)" -C "$cx" 'sources/gnutls' 'sources/freetype'
    fi

    log "gmp 6.3.0"
    cp -Rp "$cx/sources/gnutls/gmp" "$b/gmp"
    (cd "$b/gmp" && ./configure --host=$host --build=$host --prefix="$DEPS" --disable-static --enable-shared \
        --disable-assembly >"$LOGS/deps-gmp.log" 2>&1 && make -j"$JOBS" >>"$LOGS/deps-gmp.log" 2>&1 \
        && make install >>"$LOGS/deps-gmp.log" 2>&1) || { tail -20 "$LOGS/deps-gmp.log"; die "gmp failed"; }

    log "nettle 3.10.2"
    extract "$(shared_verified nettle)" "$b/nettle"
    (cd "$b/nettle" && ./configure --host=$host --build=$host --prefix="$DEPS" --libdir="$DEPS/lib" \
        --disable-static --enable-shared --disable-documentation --disable-openssl --disable-assembler \
        --with-include-path="$DEPS/include" --with-lib-path="$DEPS/lib" >"$LOGS/deps-nettle.log" 2>&1 \
        && make -j"$JOBS" >>"$LOGS/deps-nettle.log" 2>&1 && make install >>"$LOGS/deps-nettle.log" 2>&1) \
        || { tail -20 "$LOGS/deps-nettle.log"; die "nettle failed"; }

    log "gnutls 3.8.3"
    cp -Rp "$cx/sources/gnutls/gnutls" "$b/gnutls"
    # CodeWeavers' configure tests $NETTLE_LIBS unquoted, so the values must be single words.
    (cd "$b/gnutls" && ./configure --host=$host --build=$host --prefix="$DEPS" --disable-static --enable-shared \
        NETTLE_CFLAGS="-I$DEPS/include" NETTLE_LIBS="-lnettle" \
        HOGWEED_CFLAGS="-I$DEPS/include" HOGWEED_LIBS="-lhogweed" GMP_CFLAGS="-I$DEPS/include" GMP_LIBS="-lgmp" \
        --disable-maintainer-mode --disable-gost --with-included-libtasn1 --with-included-unistring --without-p11-kit \
        --without-idn --without-zstd --without-brotli --without-tpm --without-tpm2 --disable-doc --disable-manpages \
        --disable-tests --disable-tools --disable-cxx --disable-guile --disable-nls >"$LOGS/deps-gnutls.log" 2>&1 \
        && make -j"$JOBS" >>"$LOGS/deps-gnutls.log" 2>&1 && make install >>"$LOGS/deps-gnutls.log" 2>&1) \
        || { tail -20 "$LOGS/deps-gnutls.log"; die "gnutls failed"; }

    log "freetype 2.13.3"
    cp -Rp "$cx/sources/freetype" "$b/freetype"
    { cmake -S "$b/freetype" -B "$b/freetype/build" -G Ninja -DCMAKE_BUILD_TYPE=Release "${HOST_CMAKE[@]}" \
        -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_MACOS" \
        -DCMAKE_INSTALL_PREFIX="$DEPS" -DBUILD_SHARED_LIBS=ON \
        -DFT_DISABLE_PNG=ON -DFT_DISABLE_BZIP2=ON -DFT_DISABLE_BROTLI=ON -DFT_DISABLE_HARFBUZZ=ON -DFT_REQUIRE_ZLIB=ON \
        && cmake --build "$b/freetype/build" -j "$JOBS" && cmake --install "$b/freetype/build"; } \
        >"$LOGS/deps-freetype.log" 2>&1 || { tail -20 "$LOGS/deps-freetype.log"; die "freetype failed"; }

    # SDL3 + sdl2-compat (neutron's game controller stack): winebus dlopens libSDL2-2.0.0.dylib, which loads
    # libSDL3.0.dylib from its own folder. (SDL3's asserts use __FILE_NAME__, but the maps cost nothing.)
    log "SDL3 3.4.18 + sdl2-compat 2.32.74"
    extract "$(verified sdl3)" "$b/sdl3"
    extract "$(verified sdl2-compat)" "$b/sdl2-compat"
    { cmake -S "$b/sdl3" -B "$b/sdl3/build" -G Ninja -DCMAKE_BUILD_TYPE=Release "${HOST_CMAKE[@]}" -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_MACOS" -DCMAKE_INSTALL_PREFIX="$DEPS" -DCMAKE_PREFIX_PATH="$DEPS" \
        -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_TEST_LIBRARY=OFF -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF \
        && cmake --build "$b/sdl3/build" -j "$JOBS" && cmake --install "$b/sdl3/build" \
        && cmake -S "$b/sdl2-compat" -B "$b/sdl2-compat/build" -G Ninja -DCMAKE_BUILD_TYPE=Release "${HOST_CMAKE[@]}" \
        -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_MACOS" -DCMAKE_INSTALL_PREFIX="$DEPS" \
        -DCMAKE_PREFIX_PATH="$DEPS" -DSDL2COMPAT_TESTS=OFF \
        && cmake --build "$b/sdl2-compat/build" -j "$JOBS" && cmake --install "$b/sdl2-compat/build"; } \
        >"$LOGS/deps-sdl.log" 2>&1 || { tail -20 "$LOGS/deps-sdl.log"; die "SDL failed"; }
    )

    # freetype2.pc requires zlib; macOS has libz but no .pc file, and pkg-config only sees $DEPS.
    cat > "$DEPS/lib/pkgconfig/zlib.pc" <<'PC'
Name: zlib
Description: zlib from the macOS SDK
Version: 1.2.12
Libs: -lz
Cflags:
PC

    # Every dependency must be arm64-only and refer to its siblings through @rpath. Debug symbols go (strip -S): the
    # debug map of nettle's -ggdb3 objects names every object file of its build tree, and nothing that ships needs
    # them. Apple's strip by path: llvm-mingw's bin/ comes first in PATH.
    local f dep
    for f in "$DEPS"/lib/*.dylib; do
        [ -L "$f" ] && continue
        install_name_tool -id "@rpath/$(basename "$f")" "$f" 2>/dev/null || true
        { otool -L "$f" | awk 'NR>1 {print $1}' | grep "^$DEPS/lib/" || true; } | while read -r dep; do
            install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$f"
        done
        /usr/bin/strip -S "$f"
        [ "$(lipo -archs "$f")" = arm64 ] || die "$f is not arm64-only"
        otool -L "$f" | awk 'NR>1 {print $1}' | grep -E '^(/opt/homebrew|/usr/local)' && die "$f links Homebrew"
        codesign --force --sign - "$f" 2>/dev/null
    done
    ls -la "$DEPS/lib"/*.dylib
}

# ---------------------------------------------------------------------------------------------
# wine-src: Wine 11.19 + neutron's series + Proton lsteamclient in the tree + Warzag's patches
apply_series() {  # apply_series <dir> <patch>...: patch -p1, stop at the first that does not apply cleanly
    local dir="$1" p
    shift
    for p in "$@"; do
        echo "    apply $(basename "$p")"
        (cd "$dir" && patch -p1 -s -N --dry-run < "$p" >/dev/null) || die "does not apply: $p"
        (cd "$dir" && patch -p1 -s -N < "$p")
    done
}

stage_wine_src() {
    local p proton list=()
    rm -rf "$W"
    tar -xJf "$(verified wine)" -C "$SRC"
    [ -f "$W/configure.ac" ] || die "unexpected Wine tarball layout"

    log "neutron Wine series"
    for p in "$PATCHES"/wine/0*.patch; do list+=("$p"); done
    apply_series "$W" "${list[@]}"

    log "Proton lsteamclient into dlls/lsteamclient"
    proton="$(repo proton)"
    rm -rf "$W/dlls/lsteamclient"
    git -C "$proton" archive --format=tar HEAD lsteamclient | tar -x -C "$W/dlls"
    list=()
    for p in "$PATCHES"/proton/0*.patch; do list+=("$p"); done
    for p in "$PATCHES"/warzag/wz-n-proton-*.patch; do [ -f "$p" ] && list+=("$p"); done
    apply_series "$W/dlls/lsteamclient" "${list[@]}"

    log "Warzag Wine patches"
    list=()
    for p in "$PATCHES"/warzag/wz-n-0*.patch; do list+=("$p"); done
    apply_series "$W" "${list[@]}"

    log "autoreconf"
    (cd "$W" && autoreconf -f > "$LOGS/autoreconf.log" 2>&1) || { tail -20 "$LOGS/autoreconf.log"; die "autoreconf failed"; }
    # Warzag builds its own steam.exe (bridge/steam-shim), so Proton's steam_helper is not built.
    grep -q 'programs/steam_helper' "$W/configure" && die "configure still lists programs/steam_helper"
    grep -q 'dlls/lsteamclient' "$W/configure" || die "configure does not list dlls/lsteamclient"
}

# ---------------------------------------------------------------------------------------------
# wine: arm64 unix side, ARM64EC + aarch64 PE side (ARM64X), in the app-bundle layout
stage_wine() {
    [ -f "$DEPS/lib/libgnutls.30.dylib" ] || die "run the deps stage first"
    # An interrupted build resumes in the configured tree; --redo starts from a clean one.
    [ "$REDO" = 1 ] && rm -rf "$B"
    if [ -f "$B/config.status" ] && [ -f "$B/Makefile" ]; then
        log "configured tree in $B: resuming make"
    else
        wine_configure
    fi
    wine_make
    wine_sdk
}

wine_configure() {
    rm -rf "$B"; mkdir -p "$B"
    : > "$LOGS/wine-make.log"
    log "configure (log: $LOGS/wine-configure.log)"
    # Unix modules live in Contents/lib/wine/aarch64-unix and dlopen() the deps by @rpath; the loader lives in
    # Contents/MacOS. Both rpaths resolve to Contents/lib inside Warzag.app.
    # Path maps: makedep compiles the unix side's C and Objective-C (winemac.drv) with CFLAGS and its C++
    # (lsteamclient.so) with CXXFLAGS, which configure would otherwise default to "-g -O2" (a debug map naming every
    # lsteamclient object file). configure copies CROSSCFLAGS into arm64ec_CFLAGS and aarch64_CFLAGS (and their
    # CXXFLAGS), which every PE compile rule ends with: __FILE__ in Wine's DLLs (critical sections, asserts); and,
    # because arm64ec is enabled, into x86_64_CFLAGS, which compiles the x86-64 code inside ARM64EC modules
    # (#pragma makedep arm64ec_x64: ntdll's signal_x86_64.c, the rpcrt4/oleaut32 thunks, vcomp, mshtml).
    (cd "$B" && "$W/configure" \
        --prefix=/ --bindir=/MacOS --libdir=/lib --datadir=/share \
        --enable-archs=arm64ec,aarch64 --disable-tests \
        --with-coreaudio --with-freetype --with-gnutls --with-sdl \
        --without-x --without-vulkan --without-gstreamer --without-cups --without-sane --without-gphoto \
        --without-krb5 --without-pcap --without-usb --without-v4l2 --without-pulse --without-capi --without-opencl \
        --without-inotify --without-netapi --without-pcsclite --without-dbus --without-oss --without-alsa \
        --without-udev \
        CC="$HOST_CC" CXX="$HOST_CXX" OBJC="$HOST_CC" \
        CFLAGS="-O2 $NATIVE_DEFS $PREFIX_MAPS" CXXFLAGS="-O2 $PREFIX_MAPS" \
        CROSSCFLAGS="-O2 -g0 $NATIVE_DEFS $PREFIX_MAPS" \
        CPPFLAGS="-I$DEPS/include" \
        LDFLAGS="-L$DEPS/lib -Wl,-headerpad_max_install_names -Wl,-rpath,@loader_path/../.. -Wl,-rpath,@executable_path/../lib $OSO_PREFIX" \
        SDL2_CFLAGS="-I$DEPS/include/SDL2 -D_THREAD_SAFE" SDL2_LIBS="-L$DEPS/lib -lSDL2" \
        ac_cv_lib_soname_gnutls="@rpath/libgnutls.30.dylib" \
        ac_cv_lib_soname_freetype="@rpath/libfreetype.6.dylib" \
        ac_cv_lib_soname_SDL2="@rpath/libSDL2-2.0.0.dylib" \
        > "$LOGS/wine-configure.log" 2>&1) || { tail -40 "$LOGS/wine-configure.log"; die "configure failed"; }
    grep -E '#define SONAME_LIB(GNUTLS|FREETYPE|SDL2) ' "$B/include/config.h"
    grep -q '^#define SONAME_LIBSDL2 ' "$B/include/config.h" || die "configure did not find SDL2"
    grep -q '^#define SONAME_LIBGNUTLS ' "$B/include/config.h" || die "configure did not find GnuTLS"
    grep -iE "^configure: (WARNING|error)|won't be supported" "$LOGS/wine-configure.log" || true
    # The flags must have reached the Makefile (case patterns: the paths are matched literally).
    local v line
    for v in CFLAGS CXXFLAGS arm64ec_CFLAGS aarch64_CFLAGS x86_64_CFLAGS arm64ec_CXXFLAGS aarch64_CXXFLAGS LDFLAGS; do
        line="$(grep -E "^$v = " "$B/Makefile" || true) "
        case "$v $line" in
            "LDFLAGS "*" $OSO_PREFIX "*) ;;
            "LDFLAGS "*) die "configure dropped $OSO_PREFIX from LDFLAGS" ;;
            *" -ffile-prefix-map=$CACHE=/warzag-build "*" -ffile-prefix-map=$ROOT=/warzag "*) ;;
            *) die "configure dropped the path maps from $v" ;;
        esac
        case "$v $line" in "CXXFLAGS "*" -g "*) die "the unix side's CXXFLAGS ask for debug info (-g)" ;; esac
    done
}

wine_make() {
    local f
    # The deps carry @rpath install names (they ship in Contents/lib). The one build tool that links one of them,
    # sfnt2fon (FreeType, for the .fon fonts), finds it through its @loader_path/../.. rpath: the build root.
    for f in "$DEPS"/lib/libfreetype*.dylib; do ln -sf "$f" "$B/$(basename "$f")"; done
    log "make -j$JOBS (log: $LOGS/wine-make.log)"
    (cd "$B" && make -j"$JOBS" >> "$LOGS/wine-make.log" 2>&1) || { tail -60 "$LOGS/wine-make.log"; die "make failed"; }
}

wine_sdk() {
    # Headers, import libraries and tools for DXMT's winemetal (meson -Dwine_install_path), as neutron does.
    log "Wine SDK for DXMT"
    rm -rf "$SDK"
    (cd "$B" && make install DESTDIR="$SDK" > "$LOGS/wine-sdk-install.log" 2>&1) \
        || { tail -30 "$LOGS/wine-sdk-install.log"; die "SDK install failed"; }
    ln -sfn MacOS "$SDK/bin"
    [ -x "$SDK/bin/winebuild" ] && [ -f "$SDK/lib/wine/aarch64-windows/libwinecrt0.a" ] || die "incomplete Wine SDK in $SDK"
}

stage_make() {  # an incremental make in the configured Wine tree (not part of the default list)
    [ -f "$B/Makefile" ] || die "no configured Wine tree in $B"
    rm -f "$WORK/.done-install"
    wine_make
}

# ---------------------------------------------------------------------------------------------
# llvm: LLVM 15 for DXMT's airconv, exactly neutron's configuration
stage_llvm() {
    local src
    src="$(repo llvm-project)"
    rm -rf "$LLVM15" "$T/llvm-darwin-arm64-build"
    log "LLVM 15.0.7, -j$JOBS (log: $LOGS/llvm.log)"
    # Path maps, although these release libraries (no assertions) name no build path: airconv links them.
    { cmake -B "$T/llvm-darwin-arm64-build" -S "$src/llvm" -G Ninja "${HOST_CMAKE[@]}" \
        -DCMAKE_INSTALL_PREFIX="$LLVM15" -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DLLVM_HOST_TRIPLE=arm64-apple-darwin -DLLVM_ENABLE_ASSERTIONS=Off -DLLVM_ENABLE_ZSTD=Off \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_FLAGS="$PREFIX_MAPS" \
        -DCMAKE_CXX_FLAGS="-D_LIBCPP_KEEP_TRANSITIVE_INCLUDES_LLVM23 $PREFIX_MAPS" \
        -DLLVM_TARGETS_TO_BUILD="" -DLLVM_BUILD_TOOLS=Off -DLLVM_INCLUDE_BENCHMARKS=Off \
        -DBUG_REPORT_URL="https://github.com/3Shain/dxmt" -DPACKAGE_VENDOR="DXMT" \
        -DLLVM_VERSION_PRINTER_SHOW_HOST_TARGET_INFO=Off \
        && cmake --build "$T/llvm-darwin-arm64-build" -j "$JOBS" && cmake --install "$T/llvm-darwin-arm64-build"; } \
        > "$LOGS/llvm.log" 2>&1 || { tail -40 "$LOGS/llvm.log"; die "LLVM build failed"; }
    [ -f "$LLVM15/lib/libLLVMCore.a" ] || die "LLVM install incomplete"
}

# ---------------------------------------------------------------------------------------------
# fex: ARM64EC emulator DLL + macOS unixlib
copy_repo() {  # copy_repo <name> <dest>: a private copy of a verified checkout (patches never touch the cache)
    local src
    src="$(repo "$1")"
    rm -rf "$2"
    cp -R "$src" "$2"
}

stage_fex() {
    local p
    copy_repo fex "$SRC/FEX"
    for p in "$PATCHES"/fex/0*.patch; do echo "    apply $(basename "$p")"; git -C "$SRC/FEX" apply "$p"; done
    rm -rf "$WORK/fex-arm64ec" "$WORK/fex-unixlib"
    log "FEX ARM64EC (log: $LOGS/fex.log)"
    { cmake -S "$SRC/FEX" -B "$WORK/fex-arm64ec" -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_TOOLCHAIN_FILE="$SRC/FEX/Data/CMake/toolchain_mingw.cmake" -DMINGW_TRIPLE=arm64ec-w64-mingw32 \
        -DENABLE_LTO=False -DENABLE_ASSERTIONS=False -DENABLE_JEMALLOC_GLIBC_ALLOC=False -DBUILD_TESTING=False \
        -DTUNE_ARCH=generic -DTUNE_CPU=none -DRANGES_NATIVE=OFF \
        -DCMAKE_C_FLAGS="-DNEUTRON_TEB_IN_TSD $PREFIX_MAPS" -DCMAKE_CXX_FLAGS="-DNEUTRON_TEB_IN_TSD $PREFIX_MAPS" \
        -DCMAKE_ASM_FLAGS="-DNEUTRON_TEB_IN_TSD $PREFIX_MAPS" \
        && cmake --build "$WORK/fex-arm64ec" -j "$JOBS"; } > "$LOGS/fex.log" 2>&1 \
        || { tail -40 "$LOGS/fex.log"; die "FEX build failed"; }
    log "FEX unixlib"
    { cmake -S "$SRC/FEX/Source/Windows/UnixLib" -B "$WORK/fex-unixlib" -G Ninja -DCMAKE_BUILD_TYPE=Release "${HOST_CMAKE[@]}" \
        -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_MACOS" \
        -DCMAKE_CXX_FLAGS="$PREFIX_MAPS" -DCMAKE_SHARED_LINKER_FLAGS="$OSO_PREFIX" \
        && cmake --build "$WORK/fex-unixlib" -j "$JOBS"; } >> "$LOGS/fex.log" 2>&1 \
        || { tail -40 "$LOGS/fex.log"; die "FEX unixlib build failed"; }
    [ -f "$WORK/fex-arm64ec/Bin/libarm64ecfex.dll" ] && [ -f "$WORK/fex-unixlib/libarm64ecfex.so" ] \
        || die "FEX outputs missing"
    file "$WORK/fex-arm64ec/Bin/libarm64ecfex.dll" "$WORK/fex-unixlib/libarm64ecfex.so"
}

# ---------------------------------------------------------------------------------------------
# dxmt: ARM64X PE DLLs (built with -marm64x for arm64ec) + aarch64 winemetal.so with LLVM 15's airconv
stage_dxmt() {
    local p
    [ -f "$LLVM15/lib/libLLVMCore.a" ] || die "run the llvm stage first"
    [ -x "$SDK/bin/winebuild" ] || die "run the wine stage first (Wine SDK)"
    copy_repo dxmt "$SRC/dxmt"
    for p in "$PATCHES"/dxmt/0*.patch; do
        echo "    apply $(basename "$p")"
        git -C "$SRC/dxmt" apply "$p"
    done
    for p in "$PATCHES"/warzag/wz-n-dxmt-*.patch; do
        [ -f "$p" ] || continue
        echo "    apply $(basename "$p")"
        git -C "$SRC/dxmt" apply "$p"
    done
    rm -rf "$WORK/dxmt-install"
    # Path maps (path-maps.sh): the PE side through a copy of DXMT's cross file with them in c_args/cpp_args; the Mac
    # side (winemetal.so with airconv; meson's build machine, which in a cross build reads only *_FOR_BUILD) through
    # the environment: winemetal's Objective-C is C compiled with -ObjC (CFLAGS_FOR_BUILD), airconv is C++. Its
    # shaders come from stdin (wz-n-dxmt-0001).
    wz_cross_file_with_maps "$SRC/dxmt/build-arm64ec.txt" "$WORK/dxmt-cross.txt"
    log "DXMT (log: $LOGS/dxmt.log)"
    { (cd "$SRC/dxmt" && CC="$HOST_CC" CXX="$HOST_CXX" OBJC="$HOST_CC" \
        CFLAGS_FOR_BUILD="$PREFIX_MAPS" CXXFLAGS_FOR_BUILD="$PREFIX_MAPS" LDFLAGS_FOR_BUILD="$OSO_PREFIX" \
        meson setup --cross-file "$WORK/dxmt-cross.txt" \
        -Dnative_llvm_path="$LLVM15" -Dwine_install_path="$SDK" -Denable_d3d12=true \
        -Denable_nvapi=true -Denable_nvngx=true build-arm64ec --buildtype release \
        --prefix "$WORK/dxmt-install" --strip) \
        && meson compile -C "$SRC/dxmt/build-arm64ec" -j "$JOBS" && meson install -C "$SRC/dxmt/build-arm64ec"; } \
        > "$LOGS/dxmt.log" 2>&1 || { tail -40 "$LOGS/dxmt.log"; die "DXMT build failed"; }
    ls -la "$WORK/dxmt-install"/*
    [ -f "$WORK/dxmt-install/aarch64-unix/winemetal.so" ] && [ -f "$WORK/dxmt-install/aarch64-windows/nvngx.dll" ] \
        || die "DXMT outputs missing"
}

# ---------------------------------------------------------------------------------------------
# bridge: the prefix-side Steam programs (bridge/), lsteamclient itself is built in the Wine tree
spec_exports() {  # exports of lsteamclient.spec, "<name> <ordinal or -> lsteamclient.<name>"
    awk '/GameOverlayRenderer/ {exit} /^#/ || NF == 0 || / -private / {next}
         {name = $3; sub(/\(.*/, "", name); print name, ($1 == "@" ? "-" : $1), "lsteamclient." name}' "$1"
}
def_exports() {
    awk '/^[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=/ {
             sub(/=/, " = "); ord = "-"; for (i = 4; i <= NF; i++) if ($i ~ /^@[0-9]+$/) ord = substr($i, 2)
             print $1, ord, $3 }' "$1"
}

stage_bridge() {
    local out="$WORK/bridge" br="$ROOT/bridge" spec="$W/dlls/lsteamclient/lsteamclient.spec" def dll got want
    rm -rf "$out"; mkdir -p "$out"
    [ -f "$spec" ] || die "run the wine-src stage first"

    # The sources are the checkout's. None of them uses __FILE__ or assert() (and GCC's .file symbol in
    # wz-steamprobe.exe's symbol table names only the file), but the maps would turn the checkout into /warzag.
    local maps
    read -r -a maps <<< "$PREFIX_MAPS"

    log "steamclient64.dll forwarder (x86_64)"
    def="$br/forwarders/steamclient64.def"
    dll="$out/steamclient64.dll"
    diff <(spec_exports "$spec") <(def_exports "$def") > "$LOGS/forwarders-steamclient64.def.diff" \
        || { cat "$LOGS/forwarders-steamclient64.def.diff"; die "$def no longer matches lsteamclient.spec"; }
    "$GCC_MINGW/x86_64-w64-mingw32-gcc" -std=gnu17 -O2 "${maps[@]}" -Wall -Wextra -Werror -shared -nostdlib -s \
        -Wl,-e,DllMain -Wl,--subsystem,windows -Wl,--no-insert-timestamp -Wl,--disable-auto-image-base \
        -o "$dll" "$br/forwarders/dllmain.c" "$def"
    want="$(def_exports "$def" | wc -l | tr -d ' ')"
    got="$("$GCC_MINGW/x86_64-w64-mingw32-objdump" -p "$dll" | grep -c 'Forwarder RVA -- lsteamclient\.' || true)"
    [ "$got" = "$want" ] || die "$dll forwards $got exports, expected $want"
    echo "    $(basename "$dll"): $got exports forwarded to lsteamclient"

    log "steam.exe (native arm64, llvm-mingw) and wz-steamprobe.exe (x86_64, runs under FEX like the game)"
    aarch64-w64-mingw32-clang -std=gnu17 -O2 "${maps[@]}" -Wall -Wextra -Werror -municode -DUNICODE -D_UNICODE -mwindows \
        -o "$out/steam.exe" "$br/steam-shim/steam.c" -Wl,--no-insert-timestamp -luser32 -ladvapi32
    "$GCC_MINGW/x86_64-w64-mingw32-gcc" -std=gnu17 -O2 "${maps[@]}" -Wall -Wextra -Werror -municode -DUNICODE \
        -D_UNICODE -mconsole -I"$ROOT/qa/pe/common" -o "$out/wz-steamprobe.exe" "$br/steamprobe/steamprobe.c" \
        -static-libgcc -Wl,--no-insert-timestamp -ladvapi32
    file "$out"/*.exe "$out"/*.dll
    llvm-objdump -p "$out/steam.exe" | awk '/DLL Name:/ {print "    steam.exe imports " $3}'
}

# ---------------------------------------------------------------------------------------------
# install: Contents/ of Warzag.app
stage_install() {
    local unixdir="$STAGE/lib/wine/aarch64-unix" pedir="$STAGE/lib/wine/aarch64-windows" d share
    for d in "$B/Makefile" "$WORK/fex-arm64ec/Bin/libarm64ecfex.dll" "$WORK/dxmt-install/aarch64-unix/winemetal.so" \
             "$WORK/bridge/steam.exe"; do
        [ -e "$d" ] || die "missing $d (run the earlier stages)"
    done
    rm -rf "$STAGE"
    log "Wine install-lib into $STAGE"
    (cd "$B" && make install-lib DESTDIR="$STAGE" > "$LOGS/install.log" 2>&1) \
        || { tail -30 "$LOGS/install.log"; die "make install-lib failed"; }

    # The loader is the bundle's main executable (wz-n-0001); keep a link where Wine installs it.
    if [ -f "$unixdir/wine" ] && [ ! -L "$unixdir/wine" ]; then
        mkdir -p "$STAGE/MacOS"
        rm -f "$STAGE/MacOS/wine"
        mv "$unixdir/wine" "$STAGE/MacOS/wine"
        ln -s ../../../MacOS/wine "$unixdir/wine"
    fi
    [ -x "$STAGE/MacOS/wine" ] && [ -x "$STAGE/MacOS/wineserver" ] || die "loader or wineserver missing from $STAGE/MacOS"

    log "runtime libraries (gnutls, freetype, SDL) into Contents/lib"
    cp -a "$DEPS"/lib/*.dylib "$STAGE/lib/"

    log "FEX (x86-64 emulator; wine.inf registers libarm64ecfex.dll, wz-n-0004)"
    cp "$WORK/fex-arm64ec/Bin/libarm64ecfex.dll" "$pedir/"
    cp "$WORK/fex-unixlib/libarm64ecfex.so" "$unixdir/"

    log "DXMT overlay: Contents/renderers/dxmt (WINEDLLPATH_PREPEND, wz-n-0003)"
    mkdir -p "$STAGE/renderers/dxmt/aarch64-windows" "$STAGE/renderers/dxmt/aarch64-unix"
    for d in d3d11 dxgi d3d10core d3d12 winemetal nvapi64 nvngx; do
        cp "$WORK/dxmt-install/aarch64-windows/$d.dll" "$STAGE/renderers/dxmt/aarch64-windows/"
    done
    cp "$WORK/dxmt-install/aarch64-unix/winemetal.so" "$STAGE/renderers/dxmt/aarch64-unix/"

    log "Steam bridge prefix files: Contents/share/warzag/bridge"
    share="$STAGE/share/warzag/bridge"
    mkdir -p "$share/licenses"
    install -m 644 "$WORK/bridge/steam.exe" "$WORK/bridge/wz-steamprobe.exe" "$share/"
    install -m 644 "$WORK/bridge/steamclient64.dll" "$share/steamclient64-forwarder.dll"
    install -m 644 "$ROOT/bridge/prefix/steam.reg" "$share/"
    install -m 644 "$N/bridge-NOTICE" "$share/NOTICE"
    install -m 644 "$W/dlls/lsteamclient/LICENSE" "$share/licenses/lsteamclient-Steamworks-SDK-LICENSE.txt"
    install -m 644 "$ROOT/bridge/steam-shim/LICENSE" "$share/licenses/steam-shim-BSD-3-Clause.txt"
    install -m 644 "$ROOT/LICENSE" "$share/licenses/Warzag-GPL-3.0.txt"
    [ -f "$pedir/lsteamclient.dll" ] && [ -f "$unixdir/lsteamclient.so" ] || die "lsteamclient missing from the Wine install"

    if [ "$WITH_MONO" = 1 ]; then
        log "Wine Mono 11.3.0 into share/wine/mono"
        mkdir -p "$STAGE/share/wine/mono"
        tar -xJf "$(verified wine-mono)" -C "$STAGE/share/wine/mono"
    fi

    rm -rf "$STAGE/include" "$STAGE/share/man"
    # Nothing in it may name this Mac's user or where it was built: the cache, the checkout (wherever they are), the
    # home folder or the account name, as UTF-8 or UTF-16LE (the path maps above should have left none).
    log "scan the stage for build paths (tools/release/forbidden-scan.py --personal)"
    python3 -I "$ROOT/tools/release/forbidden-scan.py" --personal --path "$CACHE" --path "$ROOT" "$STAGE" \
        || die "the stage names the build machine (cache, checkout, home folder or user name); see above"
    log "stage ready: $(du -sh "$STAGE" | cut -f1)"
}

for s in "${STAGES[@]}"; do
    case "$s" in
        toolchain|deps|wine-src|wine|llvm|fex|dxmt|bridge|install) run_stage "$s" ;;
        make) stage_make ;;
        *) die "unknown stage: $s" ;;
    esac
done
log "done: ${STAGES[*]}"
