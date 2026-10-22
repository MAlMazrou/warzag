#!/bin/bash
# Sign a bundle (or one file) from the inside out: never --deep, never the hardened runtime, no entitlements.
#
#   tools/sign/sign.sh <bundle|file> [--identity <name>|adhoc]
#
# Order:
#   1. every Mach-O library: .dylib, Wine's .so unixlibs, loadable bundles (found by magic number, not by name)
#   2. every other Mach-O executable (Contents/MacOS/wineserver, Contents/Helpers/warzagctl, ...)
#   3. nested bundles (.app, .framework, .xpc, ...), deepest first
#   4. the bundle itself, which signs its main executable together with Info.plist and seals every other file
# The default identity is "Warzag Community Code Signing" from its own keychain (tools/sign/make-cert.sh); the
# keychain is unlocked with the password in the login keychain (or $WARZAG_SIGNING_PASSWORD) and is on the keychain
# search list only while this script signs (codesign finds identities nowhere else). Runs with that identity are
# serialized with a lock. "adhoc" signs ad hoc; any other name is passed to codesign as is. No secure timestamp
# (--timestamp=none): nothing here talks to Apple.
#
# Wine's unixlibs (lsteamclient.so, winemetal.so, ...) are signed like everything else; with no hardened
# runtime there is no library validation, so they load (tools/release/smoke-host.sh checks it on a real host).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tools/sign/lib.sh
. "$HERE/lib.sh"

ORIGINAL_ARGS=("$@")
TARGET=""
IDENTITY="$WZ_IDENTITY"
while [ $# -gt 0 ]; do
    case "$1" in
        --identity) [ $# -ge 2 ] || wz_die "--identity needs a value"; IDENTITY="$2"; shift 2 ;;
        -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
        -*) echo "unknown option: $1" >&2; exit 2 ;;
        *) [ -z "$TARGET" ] || wz_die "only one bundle or file at a time"; TARGET="$1"; shift ;;
    esac
done
[ -n "$TARGET" ] || { echo "usage: $0 <bundle|file> [--identity <name>|adhoc]" >&2; exit 2; }
[ -e "$TARGET" ] || wz_die "$TARGET does not exist"
TARGET="$(cd "$(dirname "$TARGET")" && pwd)/$(basename "$TARGET")"

CODESIGN=(codesign --force --timestamp=none)
if [ "$IDENTITY" = adhoc ]; then
    CODESIGN+=(--sign -)
    authority="ad hoc"
elif [ "$IDENTITY" = "$WZ_IDENTITY" ]; then
    # One signing run at a time per user (lib.sh, WZ_SIGN_LOCK): each one adds its keychain to the search list and
    # takes it off again.
    if [ -z "${WZ_SIGN_LOCK_HELD:-}" ]; then
        export WZ_SIGN_LOCK_HELD=1
        exec /usr/bin/lockf -k -t 1800 "$WZ_SIGN_LOCK" "$0" "${ORIGINAL_ARGS[@]}"
    fi
    [ -f "$WZ_KEYCHAIN" ] || wz_die "no signing keychain at $WZ_KEYCHAIN (run tools/sign/make-cert.sh)"
    PW="$(wz_keychain_password)" || wz_die "the signing keychain's password is not in the login keychain" \
        "(service $WZ_PASSWORD_SERVICE); set WARZAG_SIGNING_PASSWORD"
    security unlock-keychain -p "$PW" "$WZ_KEYCHAIN" || wz_die "cannot unlock $WZ_KEYCHAIN"
    SHA1="$(wz_identity_sha1)"
    [ -n "$SHA1" ] || wz_die "no identity \"$WZ_IDENTITY\" in $WZ_KEYCHAIN (run tools/sign/make-cert.sh)"
    if ! wz_keychain_attached; then
        trap 'wz_detach_keychain' EXIT
        wz_attach_keychain
    fi
    CODESIGN+=(--sign "$SHA1" --keychain "$WZ_KEYCHAIN")
    authority="$WZ_IDENTITY ($SHA1)"
else
    CODESIGN+=(--sign "$IDENTITY")
    authority="$IDENTITY"
fi

# codesign, minus its "replacing existing signature" chatter.
sign() {
    local out status=0
    out="$("${CODESIGN[@]}" "$@" 2>&1)" || status=$?
    [ -z "$out" ] || grep -v ': replacing existing signature$' <<<"$out" >&2 || true
    [ $status -eq 0 ] || wz_die "codesign failed (exit $status)"
}

sign_batched() {
    local batch=() file
    for file in "$@"; do
        batch+=("$file")
        if [ ${#batch[@]} -ge 64 ]; then sign "${batch[@]}"; batch=(); fi
    done
    [ ${#batch[@]} -eq 0 ] || sign "${batch[@]}"
}

if [ ! -d "$TARGET" ]; then
    sign "$TARGET"
    echo "signed $TARGET ($authority)"
    exit 0
fi

# Finder metadata and resource forks are the "detritus" codesign refuses to seal; other attributes stay.
for attribute in com.apple.FinderInfo com.apple.ResourceFork; do
    xattr -r -d "$attribute" "$TARGET" 2>/dev/null || true
done

main="$(wz_main_executable "$TARGET")"
# Nested code gets identifiers under the bundle's ("lsteamclient" -> "com.warzag.gamehost.lsteamclient"); codesign
# only prefixes identifiers without a dot, so "libgnutls.30" stays as it is.
bundle_id=""
[ ! -f "$TARGET/Contents/Info.plist" ] \
    || bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$TARGET/Contents/Info.plist" 2>/dev/null || true)"
[ -z "$bundle_id" ] || CODESIGN+=(--prefix "$bundle_id.")
libraries=()
executables=()
while IFS= read -r -d '' file; do
    [ "$file" != "$main" ] || continue
    wz_is_macho "$file" || continue
    case "$(file -b "$file")" in
        *executable*) executables+=("$file") ;;
        *) libraries+=("$file") ;;
    esac
done < <(find "$TARGET" -type f -print0)
nested=()
while IFS= read -r -d '' dir; do
    nested+=("$dir")
done < <(find "$TARGET" -mindepth 1 -depth -type d \( -name '*.app' -o -name '*.framework' -o -name '*.xpc' \
    -o -name '*.appex' -o -name '*.bundle' -o -name '*.plugin' \) -print0)

[ ${#libraries[@]} -eq 0 ] || sign_batched "${libraries[@]}"
[ ${#executables[@]} -eq 0 ] || sign_batched "${executables[@]}"
for dir in ${nested[@]+"${nested[@]}"}; do sign "$dir"; done
sign "$TARGET"

codesign --verify --strict "$TARGET" || wz_die "$TARGET does not verify after signing"
echo "signed $TARGET: ${#libraries[@]} libraries, ${#executables[@]} executables, ${#nested[@]} nested bundles," \
    "then the bundle ($authority; no hardened runtime)"
