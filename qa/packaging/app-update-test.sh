#!/bin/bash
# Tests for Warzag's own updates on real signed bundles: stand-in Warzag.app bundles signed with the project identity,
# update archives made as App/make-app.sh --dmg makes them, and app manifests signed with a scratch key by
# tools/release/mkappupdate.sh. Covers:
#   - what Warzag must refuse: another key, a manifest edited after signing, a truncated archive, another signer, an
#     app signed ad hoc, an older build, another bundle ID, a manifest of the other kind, an archive holding more than
#     Warzag.app, a quarantined file, an app naming the builder's home folder, and a published URL without the
#     release key the app pins;
#   - the swap by the new Warzag's warzagctl (`app swap`) in a scratch Applications folder and home: the probe, the
#     swap, and its refusals (a locked app, another app, a certificate the build does not pin, a staged copy changed
#     after its check);
#   - the hand-over the app makes, with the new Warzag's executable as the update helper (`--update-swap`, which never
#     starts the app): the probe, the swap once the app has quit, and the record it leaves, replaced or refused.
#
#   qa/packaging/app-update-test.sh
#
# Needs the project identity (tools/sign/make-cert.sh) and clang. Everything happens in a temporary directory; nothing
# is launched through Launch Services.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(cd "$(mktemp -d -t warzag-app-update-test)" && pwd -P)"
cleanup() {
    chflags -R nouchg "$T" 2>/dev/null || true
    rm -rf "$T"
}
trap cleanup EXIT
failed=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; failed=1; }
check() {
    local what="$1"; shift
    if "$@" >"$T/out" 2>&1; then pass "$what"; else fail "$what"; sed 's/^/      /' "$T/out"; fi
}
refute() { # refute <description> <expected text in the output> <command...>
    local what="$1" expected="$2"; shift 2
    if "$@" >"$T/out" 2>&1; then
        fail "$what (unexpectedly succeeded)"; sed 's/^/      /' "$T/out"
    elif grep -Fq -- "$expected" "$T/out"; then
        pass "$what"
    else
        fail "$what (no \"$expected\")"; sed 's/^/      /' "$T/out"
    fi
}
payload() { # payload <manifest>: the signed manifest's payload, decoded
    python3 -I -c 'import base64,json,sys; print(base64.b64decode(json.load(open(sys.argv[1]))["payload"]).decode())' \
        "$1"
}
build_of() { /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$1/Contents/Info.plist"; }

swift build --package-path "$ROOT" -c release --product warzag-release >/dev/null
swift build --package-path "$ROOT" -c release --product warzagctl >/dev/null
swift build --package-path "$ROOT" -c release --product WarzagApp >/dev/null
BIN="$(swift build --package-path "$ROOT" -c release --show-bin-path)"
RELEASE="$BIN/warzag-release"
WARZAGCTL="$BIN/warzagctl"
APP_EXECUTABLE="$BIN/WarzagApp"
FINGERPRINT="$(shasum -a 256 "$HOME/.warzag/signing/warzag-community-code-signing.cer" | cut -d' ' -f1)"
ZEROS="$(printf '%064d' 0)"

check "warzag-release keygen" "$RELEASE" keygen --out "$T/keys" --name qa
PUBKEY="$("$RELEASE" pubkey --key "$T/keys/qa.ed25519" 2>/dev/null)"
"$RELEASE" keygen --out "$T/keys" --name other >/dev/null
OTHER_KEY="$("$RELEASE" pubkey --key "$T/keys/other.ed25519" 2>/dev/null)"

printf 'int main(void) { return 0; }\n' > "$T/main.c"
clang -arch arm64 -o "$T/main-arm64" "$T/main.c"

standin() { # [PROGRAM=<executable>] standin <dir> <version> <build> [bundle id] [identity]: <dir>/Warzag.app, signed
    local app="$1/Warzag.app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources"
    cp "${PROGRAM:-$T/main-arm64}" "$app/Contents/MacOS/Warzag"
    cp "$WARZAGCTL" "$app/Contents/Helpers/warzagctl"
    # As App/make-app.sh ships them: without the debug map, whose paths name the build machine.
    strip -S -no_code_signature_warning "$app/Contents/MacOS/Warzag" "$app/Contents/Helpers/warzagctl"
    printf 'stand-in\n' > "$app/Contents/Resources/notes.txt"
    cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Warzag</string>
<key>CFBundleIdentifier</key><string>${4:-com.warzag.app}</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$2</string>
<key>CFBundleVersion</key><string>$3</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
</dict></plist>
EOF
    if [ -n "${5:-}" ]; then
        "$ROOT/tools/sign/sign.sh" "$app" --identity "$5" >/dev/null
    else
        "$ROOT/tools/sign/sign.sh" "$app" >/dev/null
    fi
}
archive() { # archive <Warzag.app> <zip>: as App/make-app.sh --dmg makes it
    mkdir -p "$(dirname "$2")"
    ditto -c -k --norsrc --noextattr --noacl --keepParent "$1" "$2"
}
mkapp() { # mkapp <archive> [options...]: tools/release/mkappupdate.sh with the scratch key and a .invalid URL
    local zip="$1"; shift
    "$ROOT/tools/release/mkappupdate.sh" --archive "$zip" --key "$T/keys/qa.ed25519" --serial 5 --expires 2 \
        --url-base https://example.invalid/app "$@"
}

# --- archive and manifest -----------------------------------------------------------------------------------------
# The update the swaps below install carries the release app executable, which is also its update helper.
PROGRAM="$APP_EXECUTABLE" standin "$T/v2" 0.0.2 2
ZIP="$T/dist/Warzag-0.0.2.zip"
archive "$T/v2/Warzag.app" "$ZIP"
check "the update archive holds only Warzag.app, without AppleDouble entries" \
    test -z "$(zipinfo -1 "$ZIP" | grep -v '^Warzag.app/' ; zipinfo -1 "$ZIP" | grep '/\._')"
check "mkappupdate.sh signs the app manifest of a stand-in update" mkapp "$ZIP" \
    --release-notes https://example.invalid/app/v0.0.2
MANIFEST="$T/dist/Warzag-0.0.2.manifest.json"
check "... of kind app, version 0.0.2, build 2" \
    grep -q '"build":"2".*"kind":"app".*"version":"0.0.2"' <(payload "$MANIFEST")
check "... naming the archive's URL" grep -qF '"url":"https://example.invalid/app/Warzag-0.0.2.zip"' <(payload "$MANIFEST")
check "... and only the manifest is added next to the archive" \
    test "$(ls -A "$T/dist" | tr '\n' ' ')" = "Warzag-0.0.2.manifest.json Warzag-0.0.2.zip "
check "warzag-release app-verify accepts it as newer than build 1" "$RELEASE" app-verify --manifest "$MANIFEST" \
    --archive "$ZIP" --pubkey "$PUBKEY" --signer-sha256 "$FINGERPRINT" --running-build 1
VERIFY=(app-verify --manifest "$MANIFEST" --archive "$ZIP" --signer-sha256 "$FINGERPRINT")

refute "another public key is refused" "manifest signed with unknown key" \
    "$RELEASE" "${VERIFY[@]}" --pubkey "$OTHER_KEY"
python3 -I - "$MANIFEST" "$T/tampered.json" <<'EOF'
import base64, json, sys
envelope = json.load(open(sys.argv[1]))
payload = base64.b64decode(envelope["payload"]).replace(b'"serial":5', b'"serial":6')
envelope["payload"] = base64.b64encode(payload).decode()
json.dump(envelope, open(sys.argv[2], "w"))
EOF
refute "a manifest edited after signing is refused" "manifest signature does not verify" \
    "$RELEASE" app-verify --manifest "$T/tampered.json" --archive "$ZIP" --pubkey "$PUBKEY"
head -c 3000 "$ZIP" > "$T/truncated.zip"
refute "a truncated archive is refused" "size mismatch" \
    "$RELEASE" app-verify --manifest "$MANIFEST" --archive "$T/truncated.zip" --pubkey "$PUBKEY"
refute "a certificate the app does not pin is refused" "code signer $FINGERPRINT is not trusted" \
    "$RELEASE" app-verify --manifest "$MANIFEST" --archive "$ZIP" --pubkey "$PUBKEY" --signer-sha256 "$ZEROS"
refute "an app signed by another certificate than the manifest names is never signed" \
    "the app is signed by $FINGERPRINT, not by $ZEROS" \
    "$RELEASE" app-manifest --archive "$ZIP" --serial 6 --expires 1 --url https://example.org/Warzag-0.0.2.zip \
    --key "$T/keys/qa.ed25519" --signer-sha256 "$ZEROS" --out "$T/other-signer.json"
refute "the same or an older build is not offered" "build 2 is not newer than the running build 2" \
    "$RELEASE" "${VERIFY[@]}" --pubkey "$PUBKEY" --running-build 2

# Kind confusion: one key signs both kinds; neither is ever read as the other.
printf 'not really a pack\n' > "$T/pack.aar"
check "a runtime manifest can be signed with the same key" "$RELEASE" manifest --pack "$T/pack.aar" --version 0.0.2 \
    --serial 7 --expires 1 --url https://example.org/pack.aar --key "$T/keys/qa.ed25519" \
    --signer-sha256 "$FINGERPRINT" --out "$T/runtime.json"
refute "... but it is refused as an app manifest" "manifest kind is runtime, not app" \
    "$RELEASE" app-verify --manifest "$T/runtime.json" --archive "$ZIP" --pubkey "$PUBKEY"
refute "and an app manifest is refused as a runtime manifest" "manifest kind is app, not runtime" \
    "$RELEASE" verify --manifest "$MANIFEST" --pack "$T/pack.aar" --pubkey "$PUBKEY" --no-install

# What mkappupdate.sh (warzag-release app-manifest) never signs.
standin "$T/other-id" 0.0.2 2 com.example.other
archive "$T/other-id/Warzag.app" "$T/other-id/Warzag-0.0.2.zip"
refute "an app with another bundle id" "the app is com.example.other, not com.warzag.app" \
    mkapp "$T/other-id/Warzag-0.0.2.zip"
standin "$T/adhoc" 0.0.2 2 com.warzag.app adhoc
archive "$T/adhoc/Warzag.app" "$T/adhoc/Warzag-0.0.2.zip"
refute "an app signed ad hoc (verify.sh)" "expected $FINGERPRINT" mkapp "$T/adhoc/Warzag-0.0.2.zip"
refute "... and in Warzag's own check" "the app is signed ad hoc, not by the project certificate" \
    "$RELEASE" app-manifest --archive "$T/adhoc/Warzag-0.0.2.zip" --serial 6 --expires 1 \
    --url https://example.org/Warzag-0.0.2.zip --key "$T/keys/qa.ed25519" --signer-sha256 "$FINGERPRINT"
mkdir -p "$T/two/content"
ditto "$T/v2/Warzag.app" "$T/two/content/Warzag.app"
printf 'extra\n' > "$T/two/content/README.txt"
(cd "$T/two/content" && ditto -c -k --norsrc --noextattr --noacl . "$T/two/Warzag-0.0.2.zip")
refute "an archive holding more than Warzag.app" "must hold exactly Warzag.app" mkapp "$T/two/Warzag-0.0.2.zip"
mkdir -p "$T/quarantine"
ditto "$T/v2/Warzag.app" "$T/quarantine/Warzag.app"
xattr -w com.apple.quarantine "0081;6716c2a0;Safari;" "$T/quarantine/Warzag.app/Contents/Resources/notes.txt"
# Made without --noextattr, so the attribute rides along as an AppleDouble entry.
(cd "$T/quarantine" && ditto -c -k --keepParent Warzag.app Warzag-0.0.2.zip)
refute "an app carrying a quarantine attribute" "Contents/Resources/notes.txt carries a quarantine attribute" \
    mkapp "$T/quarantine/Warzag-0.0.2.zip"
standin "$T/builder" 0.0.2 2
printf 'built in %s/src/warzag\n' "$HOME" > "$T/builder/Warzag.app/Contents/Resources/notes.txt"
"$ROOT/tools/sign/sign.sh" "$T/builder/Warzag.app" >/dev/null
archive "$T/builder/Warzag.app" "$T/builder/Warzag-0.0.2.zip"
refute "an app that names the builder's home folder" "names the build machine" mkapp "$T/builder/Warzag-0.0.2.zip"
PUBLISHED=("$ROOT/tools/release/mkappupdate.sh" --archive "$ZIP" --key "$T/keys/qa.ed25519" --serial 5 --expires 2
           --url-base https://example.org/app --out "$T/published")
refute "a published URL with a key the app does not pin" "must be signed with the release key the app pins" \
    env WARZAG_RELEASE_PUBKEY_FILE="$T/keys/other.ed25519.pub" "${PUBLISHED[@]}"
check "... before anything is signed" test ! -e "$T/published"
check "a published URL with the pinned release key (a scratch key pinned for the test)" \
    env WARZAG_RELEASE_PUBKEY_FILE="$T/keys/qa.ed25519.pub" "${PUBLISHED[@]}"
cp "$T/out" "$T/published.log"
check "... saying the release key comes from WARZAG_RELEASE_PUBKEY_FILE" \
    grep -q "warning: the release key comes from $T/keys/qa.ed25519.pub" "$T/published.log"

# --- the swap: the new Warzag's own warzagctl ------------------------------------------------------------------
standin "$T/v1" 0.0.1 1
mkdir -p "$T/Applications" "$T/staging"
ditto "$T/v1/Warzag.app" "$T/Applications/Warzag.app"
ditto -x -k --noqtn "$ZIP" "$T/staging"
STAGED="$T/staging/Warzag.app"
HELPER="$STAGED/Contents/Helpers/warzagctl"
LOG="$T/home/Library/Logs/Warzag/Warzag.log"
swap() { # swap <installed> [options...]: the staged copy's own warzagctl, against the scratch home
    local installed="$1"; shift
    "$HELPER" --home "$T/home" app swap --installed "$installed" --staged "$STAGED" --version 0.0.2 --build 2 \
        --signer "$FINGERPRINT" --log "$LOG" "$@"
}
check "the new warzagctl's probe passes" swap "$T/Applications/Warzag.app" --probe
check "... and changes nothing" test "$(build_of "$T/Applications/Warzag.app")" = 1
check "... but leaves the new copy next to the installed one, hidden" test "$(build_of "$T/Applications/.Warzag.app.swap-2")" = 2
check "the new warzagctl swaps" swap "$T/Applications/Warzag.app"
check "... the installed app is build 2" test "$(build_of "$T/Applications/Warzag.app")" = 2
check "... and verifies in place" "$ROOT/tools/sign/verify.sh" "$T/Applications/Warzag.app" --fingerprint "$FINGERPRINT"
check "... the previous one is gone" test "$(ls -A "$T/Applications")" = Warzag.app
check "... the checked copy stays where it was" test "$(build_of "$STAGED")" = 2
check "... and Warzag.log says so" grep -q "update: replaced $T/Applications/Warzag.app with Warzag 0.0.2 (build 2)" "$LOG"
check "the scratch home is all it touched" test "$(ls -A "$T/home/Library")" = Logs

mkdir -p "$T/Locked"
ditto "$T/v1/Warzag.app" "$T/Locked/Warzag.app"
chflags uchg "$T/Locked/Warzag.app"
refute "a locked app is not replaced" "macOS did not let Warzag replace $T/Locked/Warzag.app" \
    swap "$T/Locked/Warzag.app" --probe
check "... it is as it was, with nothing next to it" \
    test "$(build_of "$T/Locked/Warzag.app")/$(ls -A "$T/Locked")" = "1/Warzag.app"
refute "... nor by the swap itself" "macOS did not let Warzag replace" swap "$T/Locked/Warzag.app"
chflags nouchg "$T/Locked/Warzag.app"
standin "$T/notes" 1.0 9 com.example.notes
mkdir -p "$T/Others"
ditto "$T/notes/Warzag.app" "$T/Others/Notes.app"
refute "another app is never replaced" "is com.example.notes, not com.warzag.app" swap "$T/Others/Notes.app"
check "... and stays as it was" test "$(build_of "$T/Others/Notes.app")" = 9
refute "a certificate the build does not pin is refused" "is not a certificate this build trusts" \
    "$HELPER" --home "$T/home" app swap --installed "$T/Applications/Warzag.app" --staged "$STAGED" --version 0.0.2 \
    --build 2 --signer "$ZEROS"
ditto "$T/v1/Warzag.app" "$T/Changed.app"
mkdir -p "$T/ChangedApps"
mv "$T/Changed.app" "$T/ChangedApps/Warzag.app"
printf 'changed\n' > "$STAGED/Contents/Resources/notes.txt"
set +e
swap "$T/ChangedApps/Warzag.app" --probe >"$T/out" 2>&1
status=$?
set -e
if [ "$status" = 65 ] && grep -q "the downloaded Warzag failed its check" "$T/out"; then
    pass "a staged copy changed after its check is a rejection (exit 65)"
else
    fail "a staged copy changed after its check is a rejection (exit 65; got $status)"; sed 's/^/      /' "$T/out"
fi
check "... and nothing was replaced" test "$(build_of "$T/ChangedApps/Warzag.app")" = 1
printf 'stand-in\n' > "$STAGED/Contents/Resources/notes.txt"
check "the staged copy verifies again" "$ROOT/tools/sign/verify.sh" "$STAGED" --fingerprint "$FINGERPRINT"

# --- the app's hand-over: the new Warzag's own executable as the update helper ---------------------------------------
APP_HELPER="$STAGED/Contents/MacOS/Warzag"
RECORD="$T/home/Library/Caches/Warzag/AppUpdate.noindex/swap-result.json"
handover() { # handover <installed> [options...]: as the app starts it; WARZAG_HOME too, should it ever start the app
    local installed="$1"; shift
    env WARZAG_HOME="$T/home" "$APP_HELPER" --update-swap --home "$T/home" --installed "$installed" --staged "$STAGED" \
        --version 0.0.2 --build 2 --signer "$FINGERPRINT" --log "$LOG" "$@"
}
quit_app() { # a pid that has already quit, as the app that started the helper has once it swaps
    sleep 0 & local pid=$!
    wait "$pid"
    echo "$pid"
}
mkdir -p "$T/Handover"
ditto "$T/v1/Warzag.app" "$T/Handover/Warzag.app"
refute "Warzag's executable as the helper takes only its own command line" "app swap needs --installed" \
    env WARZAG_HOME="$T/home" "$APP_HELPER" --update-swap --home "$T/home"
check "the new Warzag's own executable probes (--update-swap --probe), without starting the app" \
    handover "$T/Handover/Warzag.app" --probe
check "... and changes nothing" test "$(build_of "$T/Handover/Warzag.app")" = 1
check "... nor records anything" test ! -e "$RECORD"
check "it swaps once the app that started it has quit (--wait-pid)" handover "$T/Handover/Warzag.app" --wait-pid "$(quit_app)"
check "... the installed app is build 2" test "$(build_of "$T/Handover/Warzag.app")" = 2
check "... and verifies in place" "$ROOT/tools/sign/verify.sh" "$T/Handover/Warzag.app" --fingerprint "$FINGERPRINT"
check "... with nothing next to it" test "$(ls -A "$T/Handover")" = Warzag.app
check "... and records it for the Warzag that opens next" grep -q '"result" : "replaced"' "$RECORD"
check "... and Warzag.log says so" grep -q "update: replaced $T/Handover/Warzag.app with Warzag 0.0.2 (build 2)" "$LOG"
refute "a certificate the build does not pin is refused there too" "is not a certificate this build trusts" \
    env WARZAG_HOME="$T/home" "$APP_HELPER" --update-swap --home "$T/home" --installed "$T/Handover/Warzag.app" \
    --staged "$STAGED" --version 0.0.2 --build 2 --signer "$ZEROS"
mkdir -p "$T/HandoverLocked"
ditto "$T/v1/Warzag.app" "$T/HandoverLocked/Warzag.app"
chflags uchg "$T/HandoverLocked/Warzag.app"
refute "a swap refused once the app has quit changes nothing" "macOS did not let Warzag replace" \
    handover "$T/HandoverLocked/Warzag.app" --wait-pid "$(quit_app)"
check "... it is as it was" test "$(build_of "$T/HandoverLocked/Warzag.app")" = 1
check "... and the refusal is recorded, with its reason, for the Warzag that opens next" \
    grep -q '"reason" : "macOS did not let Warzag replace' "$RECORD"
check "... as refused" grep -q '"result" : "refused"' "$RECORD"
chflags nouchg "$T/HandoverLocked/Warzag.app"
exit $failed
