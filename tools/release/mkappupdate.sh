#!/bin/bash
# Sign the app manifest of a Warzag update archive.
#
#   tools/release/mkappupdate.sh [--archive <Warzag-x.y.z.zip>] [--out <dir>] [--serial <n>] [--expires <days>]
#                                [--url-base <https URL>] [--key <Ed25519 private key>] [--release-notes <https URL>]
#                                [--min-macos <v>]
#
# Defaults: the one Warzag-<version>.zip in the main checkout's dist/ (App/make-app.sh --dmg writes it), out = the
# archive's folder, serial = now in Unix seconds (so serials only grow), expires in 60 days, the DEV key
# ~/.warzag/keys/dev.ed25519, URL base https://releases.warzag.invalid/app (pass --url-base for anything published).
# The manifest names <url-base>/<archive name>. A manifest for a URL players can reach (any host but a reserved
# .invalid name) must be signed with the release key the app pins (tools/sign/release-manifest.ed25519.pub); anything
# else is refused before signing.
#
#   1. the archive unpacks as Warzag unpacks it (ditto -x -k --noqtn) into exactly Warzag.app, which verifies against
#      the pinned project certificate and names nothing of the build machine (forbidden-scan.py --personal)
#   2. warzag-release app-manifest checks the app as Warzag checks a download, signs the envelope and checks it with
#      the app's own AppManifestVerifier
#   3. round trip: warzag-release app-verify (manifest, the archive's size and SHA-256, the unpacked app against it)
#
# Output: Warzag-<version>.manifest.json in <out>, written only once the round trip has passed. Publish the archive
# with the release and the manifest at the feed URL the app names (App/make-app.sh --update-url).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tools/sign/lib.sh
. "$ROOT/tools/sign/lib.sh"
die() { wz_die "$@"; }

common="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
MAIN="$ROOT"
[ -z "$common" ] || MAIN="$(cd "$common/.." && pwd)"

ARCHIVE=""
OUT=""
SERIAL="$(date +%s)"
EXPIRES=60
URL_BASE=""
KEY="$HOME/.warzag/keys/dev.ed25519"
NOTES=""
MIN_MACOS=""
while [ $# -gt 0 ]; do
    case "$1" in
        --archive) ARCHIVE="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --serial) SERIAL="$2"; shift 2 ;;
        --expires) EXPIRES="$2"; shift 2 ;;
        --url-base) URL_BASE="${2%/}"; shift 2 ;;
        --key) KEY="$2"; shift 2 ;;
        --release-notes) NOTES="$2"; shift 2 ;;
        --min-macos) MIN_MACOS="$2"; shift 2 ;;
        -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

if [ -z "$ARCHIVE" ]; then
    archives=()
    for candidate in "$MAIN"/dist/Warzag-*.zip; do [ ! -f "$candidate" ] || archives+=("$candidate"); done
    [ ${#archives[@]} -eq 1 ] || die "pass --archive: ${#archives[@]} Warzag-<version>.zip in $MAIN/dist" \
        "(App/make-app.sh --dmg writes one)"
    ARCHIVE="${archives[0]}"
fi
[ -f "$ARCHIVE" ] || die "no archive at $ARCHIVE"
ARCHIVE="$(cd "$(dirname "$ARCHIVE")" && pwd)/$(basename "$ARCHIVE")"
NAME="$(basename "$ARCHIVE" .zip)"
[[ "$NAME" =~ ^Warzag-[0-9]+(\.[0-9]+){1,3}$ ]] || die "the archive must be named Warzag-<version>.zip: $(basename "$ARCHIVE")"
[ -n "$OUT" ] || OUT="$(dirname "$ARCHIVE")"
[ -n "$URL_BASE" ] || URL_BASE="https://releases.warzag.invalid/app"
[ -f "$KEY" ] || die "no manifest-signing key at $KEY (warzag-release keygen --out ~/.warzag/keys --name dev)"
[ -f "$WZ_CER" ] || die "no project certificate at $WZ_CER (tools/sign/make-cert.sh)"
FINGERPRINT="$(wz_sha256_of "$WZ_CER")"
pinned="$(wz_pinned_fingerprint)"
[ -z "$pinned" ] || [ "$pinned" = "$FINGERPRINT" ] \
    || die "$WZ_CER ($FINGERPRINT) is not the certificate pinned in tools/sign/project-certificate.sha256 ($pinned)"

WORK="$(mktemp -d -t warzag-appupdate)"
trap 'rm -rf "$WORK"' EXIT

wz_note "unpack $(basename "$ARCHIVE") as Warzag does"
mkdir "$WORK/app"
ditto -x -k --noqtn "$ARCHIVE" "$WORK/app"
[ "$(ls -A "$WORK/app")" = Warzag.app ] || die "$(basename "$ARCHIVE") must hold exactly Warzag.app, not:" \
    "$(ls -A "$WORK/app" | tr '\n' ' ')"
APP="$WORK/app/Warzag.app"
# Nothing players get may name the build machine: the builder's home folder or user name, the build cache, this
# checkout (App/make-app.sh already refuses the home folder; this checks the archive as published).
SCAN="$WORK/scan.txt"
if ! python3 -I "$ROOT/tools/release/forbidden-scan.py" --personal \
        --path "${WARZAG_CACHE:-$HOME/Library/Caches/warzag-build}" --path "$MAIN" "$APP" > "$SCAN" 2>&1; then
    # The scanner's findings show the home folder as ~ and the user name as <user>.
    grep -E '^(FORBIDDEN|PERSONAL) ' "$SCAN" | head -n 10 >&2 || true
    die "the Warzag.app in $(basename "$ARCHIVE") names the build machine or holds forbidden content" \
        "(tools/release/forbidden-scan.py --personal); rebuild it with App/make-app.sh"
fi
"$ROOT/tools/sign/verify.sh" "$APP" --fingerprint "$FINGERPRINT"

wz_note "build warzag-release"
swift build --package-path "$ROOT" -c release --product warzag-release >/dev/null
RELEASE="$(swift build --package-path "$ROOT" -c release --show-bin-path)/warzag-release"
[ -x "$RELEASE" ] || die "warzag-release did not build"

# Every app players get pins one manifest key, the release key: a manifest for a URL they can reach takes that key.
if wz_reaches_players "$URL_BASE"; then
    RELEASE_KEY="$(wz_release_public_key)"
    [ -n "$RELEASE_KEY" ] || die "a manifest for $URL_BASE must be signed with the release key the app pins, and" \
        "none is pinned here ($WZ_RELEASE_KEY_FILE is missing or empty); leave --url-base out for a development update"
    [ -z "${WARZAG_RELEASE_PUBKEY_FILE:-}" ] || echo "warning: the release key comes from $WZ_RELEASE_KEY_FILE" \
        "(WARZAG_RELEASE_PUBKEY_FILE), not from the repository: do not publish this manifest" >&2
    KEY_PUBLIC="$("$RELEASE" pubkey --key "$KEY" 2>/dev/null)" \
        || die "$KEY is not a key warzag-release can sign with (warzag-release pubkey --key $KEY says why)"
    [ "$KEY_PUBLIC" = "$RELEASE_KEY" ] || die "a manifest for $URL_BASE must be signed with the release key the app" \
        "pins ($WZ_RELEASE_KEY_FILE), not with $KEY: pass --key ~/.warzag/keys/release-manifest.ed25519, or leave" \
        "--url-base out for a development update"
fi

wz_note "app manifest"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
STAGE="$WORK/out"
mkdir "$STAGE"
args=(app-manifest --archive "$ARCHIVE" --serial "$SERIAL" --expires "$EXPIRES" --url "$URL_BASE/$NAME.zip"
      --key "$KEY" --signer-sha256 "$FINGERPRINT" --out "$STAGE/$NAME.manifest.json")
[ -z "$NOTES" ] || args+=(--release-notes "$NOTES")
[ -z "$MIN_MACOS" ] || args+=(--min-macos "$MIN_MACOS")
"$RELEASE" "${args[@]}"

wz_note "round trip: warzag-release app-verify"
"$RELEASE" app-verify --manifest "$STAGE/$NAME.manifest.json" --archive "$ARCHIVE" \
    --pubkey "$("$RELEASE" pubkey --key "$KEY" 2>/dev/null)" --signer-sha256 "$FINGERPRINT"

mv -f "$STAGE/$NAME.manifest.json" "$OUT/$NAME.manifest.json"
cat <<EOF

manifest  $OUT/$NAME.manifest.json (serial $SERIAL, $EXPIRES days, key $KEY)
archive   $ARCHIVE ($(stat -f %z "$ARCHIVE") bytes)
url       $URL_BASE/$NAME.zip
signer    $FINGERPRINT
EOF
