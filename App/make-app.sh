#!/bin/bash
# Build Warzag.app (arm64), sign it with the project certificate and verify it; with --dmg also the release files.
#
#   App/make-app.sh [--version <x.y.z>] [--build <n>] [--identity <name>|adhoc] [--out <dir>]
#                   [--feed-url <https URL>] [--update-url <https URL>]
#                   [--dmg [--dist <dir>] [--dmg-url <https URL the DMG will be published at>]]
#
#   --version     CFBundleShortVersionString (default: warzagctl's version)
#   --build       CFBundleVersion, which orders updates (default: the commit count)
#   --out         where Warzag.app goes (default: build/app)
#   --feed-url    signed runtime manifest that setup installs the engine from (none: the app has no engine source)
#   --update-url  signed app manifest that Check for Updates reads (none: the app cannot update itself)
#   --dmg         also write Warzag.dmg, Warzag.dmg.sha256, install.sh (tools/release/install.sh with the DMG's
#                 SHA-256 and --dmg-url filled in) and the update archive Warzag-<version>.zip into <dist>
#                 (default: the main checkout's dist/); tools/release/mkappupdate.sh signs the archive's manifest
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tools/sign/lib.sh
. "$ROOT/tools/sign/lib.sh"
die() { wz_die "$@"; }

common="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
MAIN="$ROOT"
[ -z "$common" ] || MAIN="$(cd "$common/.." && pwd)"

VERSION=""
IDENTITY="$WZ_IDENTITY"
OUT="$ROOT/build/app"
DMG=0
DIST="$MAIN/dist"
DMG_URL=""
FEED_URL=""
UPDATE_URL=""
BUILD_NUMBER=""
while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        --build) BUILD_NUMBER="$2"; shift 2 ;;
        --identity) IDENTITY="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --dmg) DMG=1; shift ;;
        --dist) DIST="$2"; shift 2 ;;
        --dmg-url) DMG_URL="$2"; shift 2 ;;
        --feed-url) FEED_URL="$2"; shift 2 ;;
        --update-url) UPDATE_URL="$2"; shift 2 ;;
        -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done
# CFBundleShortVersionString: numbers only (it is also substituted into Info.plist with sed).
VERSION_PATTERN='^[0-9]+(\.[0-9]+){1,3}$'
[ -z "$VERSION" ] || [[ "$VERSION" =~ $VERSION_PATTERN ]] || die "--version must be numbers and dots (e.g. 0.1.0): '$VERSION'"
# CFBundleVersion orders Warzag's own updates (only a higher build is offered): a whole number.
[ -z "$BUILD_NUMBER" ] || [[ "$BUILD_NUMBER" =~ ^[0-9]{1,9}$ ]] || die "--build must be a whole number: '$BUILD_NUMBER'"
# The DMG URL goes into "${WARZAG_DMG_URL:-...}" in install.sh, which players pipe into sh: https only, and only
# characters that mean nothing there (no $ ` " \ } or spaces). The feed URLs must match too: the app accepts only
# https URLs with a host.
URL_PATTERN="^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~/%+=,@:;!*'()&?#-]*)?\$"
if [ -n "$DMG_URL" ]; then
    [ "$DMG" = 1 ] || die "--dmg-url needs --dmg"
    [[ "$DMG_URL" =~ $URL_PATTERN ]] || die "--dmg-url must be a plain https URL: '$DMG_URL'"
fi
if [ -n "$FEED_URL" ]; then
    [[ "$FEED_URL" =~ $URL_PATTERN ]] || die "--feed-url must be a plain https URL: '$FEED_URL'"
elif [ "$DMG" = 1 ]; then
    wz_note "warning: no --feed-url, so this app has no engine source (only a development engine or" \
        "warzagctl runtime install)"
fi
if [ -n "$UPDATE_URL" ]; then
    [[ "$UPDATE_URL" =~ $URL_PATTERN ]] || die "--update-url must be a plain https URL: '$UPDATE_URL'"
elif [ "$DMG" = 1 ]; then
    wz_note "warning: no --update-url, so this app cannot update itself (players download each release by hand)"
fi

if [ "$IDENTITY" = adhoc ]; then
    FINGERPRINT=adhoc
elif [ "$IDENTITY" = "$WZ_IDENTITY" ]; then
    [ -f "$WZ_CER" ] || die "no project certificate at $WZ_CER (tools/sign/make-cert.sh)"
    FINGERPRINT="$(wz_sha256_of "$WZ_CER")"
else
    FINGERPRINT=any
fi

wz_note "swift build -c release --arch arm64 (WarzagApp, warzagctl)"
BUILD=(swift build --package-path "$ROOT" -c release --arch arm64)
"${BUILD[@]}" --product WarzagApp >/dev/null
"${BUILD[@]}" --product warzagctl >/dev/null
BIN="$("${BUILD[@]}" --show-bin-path)"
for product in WarzagApp warzagctl; do
    [ -x "$BIN/$product" ] || die "$BIN/$product did not build"
    [ "$(lipo -archs "$BIN/$product")" = arm64 ] || die "$BIN/$product is not arm64-only"
done
if [ -z "$VERSION" ]; then
    VERSION="$("$BIN/warzagctl" version | awk '{print $2}')"
    [[ "$VERSION" =~ $VERSION_PATTERN ]] || die "could not read warzagctl's version; pass --version"
fi
# A release build must trust the release manifest key and never the development key (EngineKit's RuntimeTrust).
"$BIN/warzagctl" runtime trust --json | python3 -I -c '
import json, sys
trust = json.load(sys.stdin)
names = [key.get("name") for key in trust["manifestKeys"]]
sys.exit(0 if trust["build"] == "release" and "release" in names and "development" not in names else 1)
' || die "this build would trust the DEV manifest key or not the release key (warzagctl runtime trust)"
[ -n "$BUILD_NUMBER" ] || BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 0)"

APP="$OUT/Warzag.app"
C="$APP/Contents"
wz_note "assemble $APP ($VERSION, build $BUILD_NUMBER)"
rm -rf "$APP"
mkdir -p "$C/MacOS" "$C/Helpers" "$C/Resources"
cp "$BIN/WarzagApp" "$C/MacOS/Warzag"
cp "$BIN/warzagctl" "$C/Helpers/warzagctl"
# The debug map names every source and object file by absolute path (the builder's home folder). strip -S keeps the
# symbol table, so crash reports still name functions.
strip -S -no_code_signature_warning "$C/MacOS/Warzag" "$C/Helpers/warzagctl"
sed -e "s/@VERSION@/$VERSION/" -e "s/@BUILD@/$BUILD_NUMBER/" "$ROOT/App/Info.plist.in" > "$C/Info.plist"
plutil -lint -s "$C/Info.plist"
# plutil escapes the URL as a plist string. Keys must not contain dots, which plutil reads as a key path.
[ -z "$FEED_URL" ] || plutil -insert WarzagRuntimeManifestURL -string "$FEED_URL" "$C/Info.plist"
[ -z "$UPDATE_URL" ] || plutil -insert WarzagAppManifestURL -string "$UPDATE_URL" "$C/Info.plist"
printf 'APPL????' > "$C/PkgInfo"

ICON="$OUT/AppIcon.icns"
if [ ! -f "$ICON" ] || [ "$ROOT/App/make-icon.swift" -nt "$ICON" ] || [ "$ROOT/App/AppIcon.png" -nt "$ICON" ]; then
    wz_note "build the icon"
    rm -rf "$OUT/AppIcon.iconset"
    swift "$ROOT/App/make-icon.swift" "$ROOT/App/AppIcon.png" "$OUT/AppIcon.iconset"
    iconutil -c icns "$OUT/AppIcon.iconset" -o "$ICON"
    rm -rf "$OUT/AppIcon.iconset"
fi
cp "$ICON" "$C/Resources/AppIcon.icns"
python3 -I "$ROOT/App/strings-catalog.py" --check \
    || die "App/Localizable.xcstrings is out of date (python3 -I App/strings-catalog.py)"
xcrun xcstringstool compile "$ROOT/App/Localizable.xcstrings" --output-directory "$C/Resources" >/dev/null
[ -f "$C/Resources/en.lproj/Localizable.strings" ] || die "App/Localizable.xcstrings did not compile"
cp "$ROOT/LICENSE" "$C/Resources/LICENSE.txt"
cp "$ROOT/NOTICE" "$C/Resources/NOTICE.txt"
# What's New in Warzag shows the changelog of this build.
python3 -I "$ROOT/tools/release/changelog.py" check --file "$ROOT/CHANGELOG.md" >/dev/null \
    || die "CHANGELOG.md breaks its format (python3 -I tools/release/changelog.py check)"
cp "$ROOT/CHANGELOG.md" "$C/Resources/CHANGELOG.md"

python3 -I "$ROOT/tools/release/forbidden-scan.py" "$APP" >/dev/null || die "forbidden content in $APP"
# Nothing shipped may contain a path under the builder's home folder (it names their user account).
if [ -n "${HOME:-}" ] && [ "$HOME" != / ] && leaks="$(/usr/bin/grep -rlF "$HOME/" "$APP")"; then
    die "build paths under $HOME in: $(tr '\n' ' ' <<<"$leaks")"
fi

wz_note "sign ($IDENTITY)"
"$ROOT/tools/sign/sign.sh" "$APP" --identity "$IDENTITY"
"$ROOT/tools/sign/verify.sh" "$APP" --fingerprint "$FINGERPRINT"

if [ "$DMG" = 1 ]; then
    mkdir -p "$DIST"
    DIST="$(cd "$DIST" && pwd)"
    wz_note "disk image $DIST/Warzag.dmg"
    STAGE="$(mktemp -d -t warzag-dmg)"
    trap 'rm -rf "$STAGE"' EXIT
    mkdir "$STAGE/Warzag" "$STAGE/out"
    ditto "$APP" "$STAGE/Warzag/Warzag.app"
    ln -s /Applications "$STAGE/Warzag/Applications"
    # All outputs are made in $STAGE and moved into place together, so a failure never leaves a new Warzag.dmg next
    # to an install.sh that expects the old one. The image is not signed (the app inside is): Gatekeeper rejects a
    # signed image that is not notarized but does not assess an unsigned one, whose integrity Warzag.dmg.sha256
    # (checked by install.sh) and hdiutil's checksums cover.
    hdiutil create -quiet -volname Warzag -srcfolder "$STAGE/Warzag" -fs HFS+ -format UDZO "$STAGE/out/Warzag.dmg"
    hdiutil verify -quiet "$STAGE/out/Warzag.dmg"
    (cd "$STAGE/out" && shasum -a 256 Warzag.dmg > Warzag.dmg.sha256)
    # The update archive holds data, modes and links only, and must unpack (as Warzag unpacks it) into exactly this
    # app, still verifying.
    ARCHIVE="Warzag-$VERSION.zip"
    ditto -c -k --norsrc --noextattr --noacl --keepParent "$APP" "$STAGE/out/$ARCHIVE"
    mkdir "$STAGE/check"
    ditto -x -k --noqtn "$STAGE/out/$ARCHIVE" "$STAGE/check"
    [ "$(ls -A "$STAGE/check")" = Warzag.app ] || die "$ARCHIVE does not hold exactly Warzag.app"
    "$ROOT/tools/sign/verify.sh" "$STAGE/check/Warzag.app" --fingerprint "$FINGERPRINT" --quiet \
        || die "the Warzag.app in $ARCHIVE does not verify"
    DMG_SHA256="$(cut -d' ' -f1 "$STAGE/out/Warzag.dmg.sha256")"
    # Only the two assignment lines are filled in. URL_PATTERN admits &, which is "whole match" to sed: escape it and
    # the delimiter in the replacement.
    fill=(-e "/^DMG_SHA256=/s|@DMG_SHA256@|$DMG_SHA256|")
    [ -z "$DMG_URL" ] || fill+=(-e "/^DMG_URL=/s|@DMG_URL@|$(printf '%s' "$DMG_URL" | sed 's/[&|\\]/\\&/g')|")
    sed "${fill[@]}" "$ROOT/tools/release/install.sh" > "$STAGE/out/install.sh"
    sh -n "$STAGE/out/install.sh" || die "the filled-in install.sh is not valid sh"
    grep -qF "DMG_SHA256=\"\${WARZAG_DMG_SHA256:-$DMG_SHA256}\"" "$STAGE/out/install.sh" \
        || die "install.sh was not filled in with the image's SHA-256"
    for file in Warzag.dmg Warzag.dmg.sha256 install.sh "$ARCHIVE"; do
        mv -f "$STAGE/out/$file" "$DIST/$file"
    done
    echo "dmg       $DIST/Warzag.dmg ($(stat -f %z "$DIST/Warzag.dmg") bytes)"
    echo "sha256    $DMG_SHA256"
    echo "installer $DIST/install.sh${DMG_URL:+ (for $DMG_URL)}"
    echo "archive   $DIST/$ARCHIVE ($(stat -f %z "$DIST/$ARCHIVE") bytes; sign its app manifest with" \
        "tools/release/mkappupdate.sh)"
fi
echo "app       $APP ($VERSION, build $BUILD_NUMBER, signer $FINGERPRINT)"
echo "feed      ${FEED_URL:-none (no engine source)}"
echo "updates   ${UPDATE_URL:-none (this app cannot update itself)}"
