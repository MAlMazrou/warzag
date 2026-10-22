#!/bin/bash
# Assemble the engine's "Warzag.app" (arm64 only) from the stage built by runtime/n/build.sh.
#
#   runtime/n/make-host.sh [--out <dir>] [--sign adhoc|none] [--version <x.y.z>]   (defaults: build/n, adhoc, 0.2.0)
#
# Layout (EngineKit and GameKit address it this way):
#   Contents/Info.plist                        game identity, Game Mode keys, WarzagRuntimeChannel n
#                                              (runtime/gamehost/Info.plist.in)
#   Contents/MacOS/{wine,wineserver}           loader = the bundle's main executable (wz-n-0001)
#   Contents/lib/*.dylib                       arm64 gnutls/nettle/gmp, freetype, SDL3 + sdl2-compat
#   Contents/lib/wine/aarch64-unix             Wine's unix side + lsteamclient.so + libarm64ecfex.so (FEX)
#   Contents/lib/wine/aarch64-windows          ARM64X builtins + lsteamclient.dll + libarm64ecfex.dll (FEX)
#   Contents/share/wine                        wine.inf (FEX registered as the x64 emulator, wz-n-0004), nls, fonts
#   Contents/share/warzag/bridge               steam.exe (arm64), wz-steamprobe.exe, forwarders, steam.reg
#   Contents/renderers/dxmt/aarch64-{windows,unix}  DXMT overlay selected with WINEDLLPATH_PREPEND (wz-n-0003)
#   Contents/Resources/licenses
# Default output: build/n/Warzag.app of the main checkout.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CACHE="${WARZAG_CACHE:-$HOME/Library/Caches/warzag-build}"
WORK="$CACHE/work/n"
STAGE="$WORK/stage"
MAIN="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null | sed 's#/\.git$##' || true)"
[ -n "$MAIN" ] && [ -d "$MAIN" ] || MAIN="$ROOT"
OUT="$MAIN/build/n"
SIGN="adhoc"
VERSION="0.2.0"

while [ $# -gt 0 ]; do
    case "$1" in
        --out) OUT="$2"; shift 2 ;;
        --sign) SIGN="$2"; shift 2 ;;
        --version) VERSION="$2"; shift 2 ;;
        -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done
case "$SIGN" in
    adhoc|none) ;;
    *) echo "unknown --sign: $SIGN (adhoc or none)" >&2; exit 2 ;;
esac

die() { echo "error: $*" >&2; exit 1; }
[ -x "$STAGE/MacOS/wine" ] || die "no staged engine at $STAGE (run runtime/n/build.sh first)"
for f in lib/wine/aarch64-windows/libarm64ecfex.dll lib/wine/aarch64-unix/libarm64ecfex.so \
         lib/wine/aarch64-windows/lsteamclient.dll lib/wine/aarch64-unix/lsteamclient.so \
         renderers/dxmt/aarch64-unix/winemetal.so renderers/dxmt/aarch64-windows/d3d11.dll \
         share/warzag/bridge/steam.exe; do
    [ -e "$STAGE/$f" ] || die "stage is missing $f"
done

APP="$OUT/Warzag.app"
C="$APP/Contents"
rm -rf "$APP"
mkdir -p "$C/Resources/licenses"

echo "==> copy the engine"
ditto "$STAGE/MacOS" "$C/MacOS"
ditto "$STAGE/lib" "$C/lib"
ditto "$STAGE/share" "$C/share"
ditto "$STAGE/renderers" "$C/renderers"

echo "==> Info.plist"
build="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 0)"
sed -e "s/@VERSION@/$VERSION/" -e "s/@BUILD@/$build/" "$ROOT/runtime/gamehost/Info.plist.in" > "$C/Info.plist"
plutil -lint -s "$C/Info.plist"
# WarzagRuntimeChannel must agree with the loader's architecture (arm64 = n): RuntimeHostChannel, RuntimeInstaller
# and mkpack.sh compare the two.
[ "$(/usr/libexec/PlistBuddy -c 'Print :WarzagRuntimeChannel' "$C/Info.plist" 2>/dev/null)" = n ] \
    || die "Info.plist does not declare WarzagRuntimeChannel n"
printf 'APPL????' > "$C/PkgInfo"

echo "==> licenses"
# Each component's license, and the notices of the code under other licenses that is compiled into the bundle's
# binaries (*-third-party-notices.txt).
L="$C/Resources/licenses"
WINE_SRC="$WORK/src/wine-$(jq -r '.archives.wine.version' "$ROOT/runtime/n/inputs.lock.json")"
FEX="$WORK/src/FEX"
DXMT="$WORK/src/dxmt"
DEPS="$WORK/deps-build"
LLVM="$WORK/repos/llvm-project/llvm"
section() { printf '\n===== %s =====\n\n' "$1"; }
# excerpt <file> <from> <to>: a license kept in a source file's header, from the first line matching the regex <from>
# through the next one matching <to>, without the comment markers.
excerpt() {
    tr -d '\r' < "$1" \
        | awk -v from="$2" -v to="$3" '!on && $0 ~ from { on = 1 } on && !done { print; done = $0 ~ to }
                                      END { exit !done }' \
        | sed -E 's@^[[:space:]]*(/\*+|\*+|//+|#+)( |$)@@' || die "no license text in $1"
}
# mit <copyright>: the copyright lines and the terms of the MIT License (FEX's LICENSE), for files that only name it.
mit() { printf '%s\n\n' "$1"; sed -n '/^Permission is hereby granted/,$p' "$FEX/LICENSE"; }

cp "$ROOT/LICENSE" "$L/Warzag-GPL-3.0.txt"
cp "$ROOT/runtime/licenses/Wine-COPYING.LIB.txt" "$ROOT/runtime/licenses/Wine-LICENSE.txt" "$L/"
cp "$WINE_SRC/NOTICES.md" "$L/Wine-NOTICES.md"

cp "$DXMT/LICENSE" "$L/DXMT-LICENSE.txt"
cp "$DXMT/COPYING.LIB" "$L/DXMT-COPYING.LIB.txt"
cp "$DXMT/external/nvapi/License.txt" "$L/DXMT-nvapi-headers-MIT.txt"
microsoft="$(grep -h -m1 -o 'Copyright (c) Microsoft Corporation\.' "$DXMT/libs/DXBCParser/ShaderBinary.cpp")" \
    || die "no copyright line in DXMT's libs/DXBCParser"
rebohle="$(grep -h -o 'Copyright (c) [0-9-]* Philip Rebohle' \
    "$DXMT/src/util/util_md5.cpp" "$DXMT/src/util/util_svector.hpp" | sort -u)" \
    || die "no copyright line in DXMT's src/util/util_md5.cpp"
{
    echo "Third-party code in DXMT (Contents/renderers/dxmt)."
    section "libs/DXBCParser (Microsoft's DXBC parser)"
    mit "$microsoft"
    section "src/util/util_md5.cpp, util_md5.hpp, util_svector.hpp (from dxbc-spirv)"
    mit "$rebohle"
    section "LICENSE.OLD (code from DXMT 0.80 and earlier)"
    cat "$DXMT/LICENSE.OLD"
    echo
} > "$L/DXMT-third-party-notices.txt"

cp "$FEX/LICENSE" "$L/FEX-LICENSE.txt"
# What libarm64ecfex.dll contains besides FEX: the externals on its link line (not vixl or zydis), the header-only
# libraries its sources include, the VIXL code in CodeEmitter and the musl functions of its CRT.
musl="$(grep -h 'SPDX-FileCopyrightText:' "$FEX"/Source/Windows/Common/CRT/Musl/*.[ch] \
    | sed 's/.*SPDX-FileCopyrightText: //' | sort -u)" || die "no copyright lines in FEX's CRT/Musl"
{
    echo "Third-party code in libarm64ecfex.dll (FEX)."
    for f in External/cephes/LICENSE External/fmt/LICENSE External/range-v3/LICENSE.txt External/rpmalloc/LICENSE \
             External/tiny-json/LICENSE External/unordered_dense/LICENSE External/xxhash/LICENSE \
             Source/Common/cpp-optparse/LICENSE; do
        section "${f%/*}"
        cat "$FEX/$f"
    done
    section "External/SoftFloat-3e"
    excerpt "$FEX/External/SoftFloat-3e/include/SoftFloat-3e/softfloat_types.h" 'part of the SoftFloat' 'SUCH DAMAGE'
    section "CodeEmitter/CodeEmitter/VixlUtils.inl (from VIXL)"
    excerpt "$FEX/CodeEmitter/CodeEmitter/VixlUtils.inl" 'VIXL authors' 'SUCH DAMAGE'
    section "Source/Windows/Common/CRT/Musl (from musl)"
    mit "$musl"
} > "$L/FEX-third-party-notices.txt"

cp "$LLVM/LICENSE.TXT" "$L/LLVM-LICENSE.txt"
{
    echo "Third-party code in LLVM's Support library, linked into winemetal.so."
    section "lib/Support/regcomp.c, regexec.c, regerror.c, regfree.c"
    cat "$LLVM/lib/Support/COPYRIGHT.regex"
    section "lib/Support/regstrlcpy.c"
    excerpt "$LLVM/lib/Support/regstrlcpy.c" 'Todd C. Miller' 'PERFORMANCE OF THIS SOFTWARE'
    section "lib/Support/ConvertUTF.cpp"
    excerpt "$LLVM/lib/Support/ConvertUTF.cpp" 'Copyright 2001-2004 Unicode' 'remains attached'
} > "$L/LLVM-third-party-notices.txt"

cp "$DEPS/sdl3/LICENSE.txt" "$L/SDL3-LICENSE.txt"
{
    echo "Third-party code in libSDL3.0.dylib (SDL)."
    section "src/video/yuv2rgb"
    cat "$DEPS/sdl3/src/video/yuv2rgb/LICENSE"
} > "$L/SDL3-third-party-notices.txt"
cp "$DEPS/sdl2-compat/LICENSE.txt" "$L/sdl2-compat-LICENSE.txt"

cp "$DEPS/gnutls/LICENSE" "$L/GnuTLS-LICENSE.txt"
cp "$DEPS/gnutls/doc/COPYING.LESSER" "$L/GnuTLS-LGPL-2.1.txt"
{
    echo "Third-party code in libgnutls.30.dylib (GnuTLS)."
    section "lib/accelerated/aarch64 (CRYPTOGAMS)"
    excerpt "$DEPS/gnutls/lib/accelerated/aarch64/macosx/aes-aarch64.s" 'Andy Polyakov' 'SUCH DAMAGE'
    section "lib/inih"
    cat "$DEPS/gnutls/lib/inih/LICENSE.txt"
    section "lib/extras/randomart.c (from OpenSSH)"
    excerpt "$DEPS/gnutls/lib/extras/randomart.c" 'Markus Friedl' 'SUCH DAMAGE'
} > "$L/GnuTLS-third-party-notices.txt"

cp "$DEPS/nettle/COPYING.LESSERv3" "$L/nettle-LGPL-3.0.txt"
floodyberry="$(grep -m1 -o 'Copyright: .*(floodyberry)' "$DEPS/nettle/poly1305-internal.c")" \
    || die "no copyright line in nettle's poly1305-internal.c"
{
    echo "Third-party code in libnettle.8.dylib (Nettle)."
    section "gosthash94.c, gost28147.c"
    excerpt "$DEPS/nettle/gosthash94.c" 'Aleksey Kravchenko' 'DEALINGS IN THE SOFTWARE'
    section "poly1305-internal.c (from poly1305-donna)"
    printf '%s\n\n' "$floodyberry"
    excerpt "$DEPS/nettle/poly1305-internal.c" 'Permission is hereby granted' 'DEALINGS IN THE SOFTWARE'
} > "$L/nettle-third-party-notices.txt"
cp "$DEPS/gmp/COPYING.LESSERv3" "$L/GMP-LGPL-3.0.txt"

# The FreeType License asks binary distributions to credit the FreeType Project, with the year of the version used.
ft_year="$(grep -m1 'Copyright (C) 1996-' "$DEPS/freetype/include/freetype/freetype.h" \
    | sed 's/.*1996-\([0-9]*\).*/\1/')" || die "no copyright year in FreeType's freetype.h"
cp "$DEPS/freetype/LICENSE.TXT" "$L/FreeType-LICENSE.txt"
cp "$DEPS/freetype/docs/FTL.TXT" "$L/FreeType-FTL.txt"
{
    echo "Portions of this software are copyright (C) $ft_year The FreeType Project (https://freetype.org)."
    echo "All rights reserved."
    echo
    echo "Code in libfreetype.6.dylib under other licenses (FreeType-LICENSE.txt):"
    section "src/bdf (BDF driver)"
    excerpt "$DEPS/freetype/src/bdf/README" '^Copyright .C. 2001-2002' '^THE USE OR OTHER DEALINGS'
    section "src/pcf (PCF driver)"
    excerpt "$DEPS/freetype/src/pcf/README" '^Copyright .C. 2000' 'DEALINGS IN THE SOFTWARE'
    section "src/base/fthash.c"
    excerpt "$DEPS/freetype/src/base/fthash.c" 'Computing Research Labs' 'DEALINGS IN THE SOFTWARE'
} > "$L/FreeType-third-party-notices.txt"

# The notices mingw-w64 requires of binaries linked with its runtime.
cp "$WORK/repos/mingw-w64/COPYING.MinGW-w64-runtime/COPYING.MinGW-w64-runtime.txt" "$L/mingw-w64-runtime-COPYING.txt"
cp "$ROOT/runtime/n/patches/README.md" "$L/engine-patches.md"
# Every file and every section of the notices must have found its text.
for f in "$L"/*; do
    awk '/^===== .* =====$/ { if (s && !n) bad = 1; s = 1; n = 0; next } NF { n++ }
         END { exit bad || !NR || (s && !n) }' "$f" || die "license text missing in ${f##*/}"
done

# Sanity: every Mach-O must be arm64-only (nothing here can run under Rosetta), nothing may point at Homebrew or
# the build machine, and every PE must be an ARM64/ARM64EC/ARM64X builtin, except the x86 programs Warzag runs
# under FEX on purpose (bridge forwarders and the probe).
echo "==> check Mach-O files (arm64 only)"
bad=0
macho=0
while IFS= read -r -d '' f; do
    if file -b "$f" | grep -q 'Mach-O'; then
        macho=$((macho + 1))
        archs="$(lipo -archs "$f" 2>/dev/null || true)"
        [ "$archs" = "arm64" ] || { echo "  not arm64-only: $f ($archs)"; bad=1; }
        if otool -L "$f" | awk 'NR>1 {print $1}' | grep -E "^(/opt/homebrew|/usr/local|$CACHE)" >/dev/null; then
            echo "  absolute build path in: $f"; otool -L "$f" | grep -E "/opt/homebrew|/usr/local|$CACHE"; bad=1
        fi
    fi
done < <(find "$C/MacOS" "$C/lib" "$C/renderers" -type f -print0)
[ $bad -eq 0 ] || die "Mach-O checks failed"
echo "  $macho Mach-O files, all arm64-only"

echo "==> check PE files (arm64 / arm64ec / arm64x only, except the bridge's x86 programs)"
pe_x86=()
pe_summary="$(python3 -I "$ROOT/qa/n/pe-arch.py" "$C/lib/wine" "$C/renderers" "$C/share/warzag" | cut -f1 | sort | uniq -c | tr '\n' ' ')"
while IFS=$'\t' read -r kind f; do
    case "$kind" in
        arm64|arm64ec|arm64x) ;;
        *)
            case "$f" in
                "$C/share/warzag/bridge/"*) pe_x86+=("${f#$C/}($kind)") ;;
                *) echo "  $kind PE outside the bridge: ${f#$C/}"; bad=1 ;;
            esac ;;
    esac
done < <(python3 -I "$ROOT/qa/n/pe-arch.py" "$C/lib/wine" "$C/renderers" "$C/share/warzag")
[ $bad -eq 0 ] || die "PE checks failed"
echo "  $pe_summary"
echo "  x86 PE files (Windows programs that run under FEX on purpose): ${pe_x86[*]}"

python3 -I "$ROOT/tools/release/forbidden-scan.py" "$APP" || die "forbidden content in $APP"

if [ "$SIGN" = adhoc ]; then
    echo "==> ad-hoc sign (inside out, no hardened runtime, no entitlements)"
    find "$C/lib" "$C/renderers" -type f \( -name '*.dylib' -o -name '*.so' \) -print0 \
        | xargs -0 -n 50 codesign --force --sign - --timestamp=none
    codesign --force --sign - --timestamp=none "$C/MacOS/wineserver"
    codesign --force --sign - --timestamp=none "$APP"
    # As EngineKit validates a runtime host: nested code, strict, all architectures.
    codesign --verify --deep --strict --all-architectures "$APP" || die "signature check failed"
    echo "  signature ok"
    codesign -d --entitlements - "$C/MacOS/wine" 2>/dev/null | grep -q 'key' && die "unexpected entitlements"
fi

echo "==> $APP ($(du -sh "$APP" | cut -f1))"
