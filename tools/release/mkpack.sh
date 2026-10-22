#!/bin/bash
# Build a signed runtime pack and its signed manifest from the engine's game host (Warzag.app).
#
#   tools/release/mkpack.sh [--host <Warzag.app>] [--out <dir>] [--version <x.y.z>] [--serial <n>]
#                           [--expires <days>] [--url-base <https URL>] [--key <Ed25519 private key>]
#                           [--identity <name>] [--min-launcher <v>] [--min-macos <v>] [--no-smoke]
#                           [--allow-builder-paths]
#
# Defaults: host <main checkout>/build/n/Warzag.app (runtime/n/make-host.sh), out <main checkout>/dist, version = the
# host's CFBundleShortVersionString, serial = now in Unix seconds (so serials only grow), expires in 60 days, the DEV
# key ~/.warzag/keys/dev.ed25519 (warzag-release keygen), identity "Warzag Community Code Signing", URL base
# https://releases.warzag.invalid/runtime/n (pass --url-base for anything published). <main checkout> is this
# checkout, or the one a git worktree belongs to.
#
# A manifest for a URL players can reach (any host but a reserved .invalid name) must be signed with the release key
# the app pins, whose public half is tools/sign/release-manifest.ed25519.pub (--key
# ~/.warzag/keys/release-manifest.ed25519); anything else is refused before the host is cloned or signed. The DEV key
# is for development packs (warzagctl runtime install --pubkey).
#
# Checks the host (every Mach-O file arm64-only, WarzagRuntimeChannel n, nothing naming the build machine;
# --allow-builder-paths makes the last a warning, for a pack that stays on this Mac), clones and signs it
# (tools/sign/sign.sh, verify.sh), archives it (aa, lzfse, Warzag.app/ at the root, no owners, flags or extended
# attributes) and signs the manifest (warzag-release manifest). Then a round trip: warzag-release verify with a
# RuntimeInstaller run in a scratch home, aa extract, verify.sh, `wine --version` and tools/release/smoke-host.sh
# (skip with --no-smoke).
#
# Output: WarzagRuntime-n-<version>.aar, .aar.sha256 (shasum format) and .manifest.json (the signed envelope the app
# fetches), moved into <out> only after the round trip passed; a failed run leaves <out> as it was.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tools/sign/lib.sh
. "$ROOT/tools/sign/lib.sh"
die() { wz_die "$@"; }

common="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
MAIN="$ROOT"
[ -z "$common" ] || MAIN="$(cd "$common/.." && pwd)"

HOST=""
OUT="$MAIN/dist"
VERSION=""
SERIAL="$(date +%s)"
EXPIRES=60
CHANNEL=n
URL_BASE=""
KEY="$HOME/.warzag/keys/dev.ed25519"
IDENTITY="$WZ_IDENTITY"
MIN_LAUNCHER=""
MIN_MACOS=""
SMOKE=1
ALLOW_BUILDER_PATHS=0
while [ $# -gt 0 ]; do
    case "$1" in
        --host) HOST="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --version) VERSION="$2"; shift 2 ;;
        --serial) SERIAL="$2"; shift 2 ;;
        --expires) EXPIRES="$2"; shift 2 ;;
        --url-base) URL_BASE="${2%/}"; shift 2 ;;
        --key) KEY="$2"; shift 2 ;;
        --identity) IDENTITY="$2"; shift 2 ;;
        --min-launcher) MIN_LAUNCHER="$2"; shift 2 ;;
        --min-macos) MIN_MACOS="$2"; shift 2 ;;
        --no-smoke) SMOKE=0; shift ;;
        --allow-builder-paths) ALLOW_BUILDER_PATHS=1; shift ;;
        -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

[ -n "$HOST" ] || HOST="$MAIN/build/n/Warzag.app"
[ -x "$HOST/Contents/MacOS/wine" ] || die "no game host at $HOST (runtime/n/make-host.sh)"
[ "$(basename "$HOST")" = "Warzag.app" ] || die "the host bundle must be named Warzag.app (RuntimeInstaller looks for it)"
loader="$(lipo -archs "$HOST/Contents/MacOS/wine" 2>/dev/null || true)"
case "$loader" in
    arm64) ;;
    *) die "$HOST/Contents/MacOS/wine is ${loader:-not a Mach-O file}, not arm64-only" ;;
esac
declared="$(/usr/libexec/PlistBuddy -c 'Print :WarzagRuntimeChannel' "$HOST/Contents/Info.plist" 2>/dev/null || true)"
case "$declared" in
    "") die "$HOST's Info.plist does not declare WarzagRuntimeChannel n (runtime/n/make-host.sh writes it)" ;;
    n) ;;
    *) die "$HOST's Info.plist says channel $declared, not n" ;;
esac
# Every Mach-O file of the host is arm64-only: nothing in a pack may need Rosetta.
wrong=0
while IFS= read -r -d '' file; do
    if wz_is_macho "$file"; then
        archs="$(lipo -archs "$file" 2>/dev/null || true)"
        if [ "$archs" != arm64 ]; then
            echo "not arm64-only: ${file#"$HOST"/} ($archs)" >&2
            wrong=$((wrong + 1))
        fi
    fi
done < <(find "$HOST/Contents" -type f -print0)
[ "$wrong" = 0 ] || die "$wrong Mach-O file(s) in $HOST are not arm64-only"
[ -n "$URL_BASE" ] || URL_BASE="https://releases.warzag.invalid/runtime/$CHANNEL"

# Nothing published may name the build machine (App/make-app.sh refuses it for the app): the builder's home folder or
# user name, nor the build cache or this checkout wherever they are. runtime/n/build.sh maps source paths away
# (-ffile-prefix-map); a host built without that still names them.
REBUILD="runtime/n/build.sh, every stage"
SCAN="$(mktemp -t warzag-personal-scan)"
if ! python3 -I "$ROOT/tools/release/forbidden-scan.py" --personal \
        --path "${WARZAG_CACHE:-$HOME/Library/Caches/warzag-build}" --path "$MAIN" "$HOST" > "$SCAN" 2>&1; then
    found="$(grep -c '^PERSONAL ' "$SCAN" || true)"
    forbidden="$(grep -c '^FORBIDDEN ' "$SCAN" || true)"
    # The scanner's findings show the home folder as ~ and the user name as <user>.
    grep -E '^(FORBIDDEN|PERSONAL) ' "$SCAN" | head -n 10 >&2 || true
    rm -f "$SCAN"
    [ "$forbidden" = 0 ] || die "forbidden content in $HOST (tools/release/forbidden-scan.py $HOST)"
    if [ "$ALLOW_BUILDER_PATHS" = 1 ]; then
        echo "warning: $found file(s) in the host name the build machine (home folder, user name, build cache or" \
            "checkout); do not publish this pack (rebuild the runtime: $REBUILD)" >&2
    else
        die "$found file(s) in $HOST name the build machine (home folder, user name, build cache or checkout):" \
            "rebuild the runtime ($REBUILD), or pass --allow-builder-paths for a pack that stays on this Mac"
    fi
fi
rm -f "$SCAN"
[ -f "$KEY" ] || die "no manifest-signing key at $KEY (warzag-release keygen --out ~/.warzag/keys --name dev)"
[ "$IDENTITY" != adhoc ] || die "packs must be signed with a certificate: the manifest pins its fingerprint"
[ -n "$VERSION" ] || VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$HOST/Contents/Info.plist")"
NAME="WarzagRuntime-$CHANNEL-$VERSION"

# The signer fingerprint the manifest will pin.
if [ "$IDENTITY" = "$WZ_IDENTITY" ]; then
    [ -f "$WZ_CER" ] || die "no project certificate at $WZ_CER (tools/sign/make-cert.sh)"
    FINGERPRINT="$(wz_sha256_of "$WZ_CER")"
    pinned="$(wz_pinned_fingerprint)"
    [ -z "$pinned" ] || [ "$pinned" = "$FINGERPRINT" ] \
        || die "$WZ_CER ($FINGERPRINT) is not the certificate pinned in tools/sign/project-certificate.sha256 ($pinned)"
fi

wz_note "build warzag-release"
swift build --package-path "$ROOT" -c release --product warzag-release >/dev/null
RELEASE="$(swift build --package-path "$ROOT" -c release --show-bin-path)/warzag-release"
[ -x "$RELEASE" ] || die "warzag-release did not build"

# Every app players get pins one manifest key, the release key (EngineKit's RuntimeTrust holds the key in
# tools/sign/release-manifest.ed25519.pub; a test compares them), so they all refuse a manifest signed with any other.
# The round trip below verifies with the public half of --key and cannot see that.
if wz_reaches_players "$URL_BASE"; then
    RELEASE_KEY="$(wz_release_public_key)"
    [ -n "$RELEASE_KEY" ] || die "a manifest for $URL_BASE must be signed with the release key the app pins, and" \
        "none is pinned here ($WZ_RELEASE_KEY_FILE is missing or empty); leave --url-base out for a development pack"
    [ -z "${WARZAG_RELEASE_PUBKEY_FILE:-}" ] || echo "warning: the release key comes from $WZ_RELEASE_KEY_FILE" \
        "(WARZAG_RELEASE_PUBKEY_FILE), not from the repository: do not publish this pack" >&2
    KEY_PUBLIC="$("$RELEASE" pubkey --key "$KEY" 2>/dev/null)" \
        || die "$KEY is not a key warzag-release can sign with (warzag-release pubkey --key $KEY says why)"
    [ "$KEY_PUBLIC" = "$RELEASE_KEY" ] || die "a manifest for $URL_BASE must be signed with the release key the app" \
        "pins ($WZ_RELEASE_KEY_FILE), not with $KEY: pass --key ~/.warzag/keys/release-manifest.ed25519, or leave" \
        "--url-base out for a development pack"
fi

mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
WORK="$(mktemp -d "$OUT/.mkpack.XXXXXX")"
EXTRACTED=""
cleanup() { rm -rf "$WORK"; [ -z "$EXTRACTED" ] || rm -rf "$EXTRACTED"; }
trap cleanup EXIT

wz_note "clone $HOST"
cp -cR "$HOST" "$WORK/Warzag.app"
python3 -I "$ROOT/tools/release/forbidden-scan.py" "$WORK/Warzag.app" >/dev/null || die "forbidden content in $HOST"

wz_note "sign ($IDENTITY)"
"$ROOT/tools/sign/sign.sh" "$WORK/Warzag.app" --identity "$IDENTITY"
if [ -z "${FINGERPRINT:-}" ]; then
    codesign -d --extract-certificates="$WORK/cert" "$WORK/Warzag.app" 2>/dev/null
    FINGERPRINT="$(wz_sha256_of "$WORK/cert0")"
fi
"$ROOT/tools/sign/verify.sh" "$WORK/Warzag.app" --fingerprint "$FINGERPRINT"

# The outputs are made and checked under $WORK and only moved into $OUT once the round trip has passed: a failed run
# never leaves a pack with a valid-looking signed manifest in $OUT, nor removes the previous one.
STAGE="$WORK/out"
mkdir "$STAGE"

wz_note "archive $NAME.aar"
aa archive -D "$WORK/Warzag.app" -o "$STAGE/$NAME.aar" -a lzfse -exclude-field uid,gid,flg,btm,ctm,xat,acl
[ "$(aa list -i "$STAGE/$NAME.aar" | head -n 1)" = "Warzag.app" ] || die "the archive does not start with Warzag.app/"
(cd "$STAGE" && shasum -a 256 "$NAME.aar" > "$NAME.aar.sha256")

wz_note "manifest"
manifest_args=(manifest --pack "$STAGE/$NAME.aar" --version "$VERSION" --serial "$SERIAL" --expires "$EXPIRES"
               --url "$URL_BASE/$NAME.aar" --key "$KEY" --signer-sha256 "$FINGERPRINT"
               --out "$STAGE/$NAME.manifest.json")
[ -z "$MIN_LAUNCHER" ] || manifest_args+=(--min-launcher "$MIN_LAUNCHER")
[ -z "$MIN_MACOS" ] || manifest_args+=(--min-macos "$MIN_MACOS")
"$RELEASE" "${manifest_args[@]}"

wz_note "round trip: warzag-release verify (with a RuntimeInstaller run)"
PUBKEY="$("$RELEASE" pubkey --key "$KEY" 2>/dev/null)"
"$RELEASE" verify --manifest "$STAGE/$NAME.manifest.json" --pack "$STAGE/$NAME.aar" --pubkey "$PUBKEY" \
    --signer-sha256 "$FINGERPRINT"

wz_note "round trip: aa extract, verify.sh, wine --version"
EXTRACTED="$(mktemp -d -t warzag-pack-check)"
aa extract -i "$STAGE/$NAME.aar" -d "$EXTRACTED"
"$ROOT/tools/sign/verify.sh" "$EXTRACTED/Warzag.app" --fingerprint "$FINGERPRINT"
version="$(env -i HOME="$HOME" PATH=/usr/bin:/bin "$EXTRACTED/Warzag.app/Contents/MacOS/wine" --version)" \
    || die "the extracted host's wine --version failed"
[ -n "$version" ] || die "the extracted host's wine --version printed nothing"
echo "extracted host: wine --version = $version"
if [ "$SMOKE" = 1 ]; then
    wz_note "round trip: smoke-host.sh on the extracted host"
    "$ROOT/tools/release/smoke-host.sh" "$EXTRACTED/Warzag.app"
fi

# Same volume, so each move is a rename; the manifest goes last.
mv -f "$STAGE/$NAME.aar" "$OUT/$NAME.aar"
mv -f "$STAGE/$NAME.aar.sha256" "$OUT/$NAME.aar.sha256"
mv -f "$STAGE/$NAME.manifest.json" "$OUT/$NAME.manifest.json"
size="$(stat -f %z "$OUT/$NAME.aar")"
cat <<EOF

pack      $OUT/$NAME.aar ($size bytes)
sha256    $(cut -d' ' -f1 "$OUT/$NAME.aar.sha256")
manifest  $OUT/$NAME.manifest.json (serial $SERIAL, $EXPIRES days, key $KEY)
signer    $FINGERPRINT ($IDENTITY)
url       $URL_BASE/$NAME.aar
EOF
