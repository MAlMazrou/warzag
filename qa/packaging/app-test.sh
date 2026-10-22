#!/bin/bash
# Tests for App/make-app.sh's output and tools/release/install.sh.
#
#   qa/packaging/app-test.sh [--app <Warzag.app> --dmg <Warzag.dmg>] [--launch]
#
# Without --app/--dmg it builds both into a temporary directory with App/make-app.sh --dmg (project identity) and
# checks what else make-app.sh wrote: the feeds in Info.plist, the update archive, Warzag.dmg.sha256, install.sh.
# Then:
#   - the app: signature, Info.plist, architectures, its changelog, no build paths and no debug map; make-app.sh
#     refuses bad arguments before it builds or writes anything;
#   - the disk image: not signed itself, hdiutil verify, Warzag.app plus an Applications link;
#   - only with --launch (it puts Warzag in the Dock for a few seconds): the app starts in the background against a
#     scratch home (CFFIXED_USER_HOME/HOME), stays up for 5 s and quits on SIGTERM;
#   - install.sh: installs from a file:// URL, replaces an existing copy and puts it back when the swap fails,
#     refuses a wrong checksum, a non-https URL or a running copy, works piped into sh and with a relative --dest,
#     and the release copy uses its embedded checksum.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP=""
DMG=""
LAUNCH=0
# The runtime feed and the app feed the built app gets (a query with & checks that each reaches Info.plist unchanged).
FEED="https://example.org/runtime/n/WarzagRuntime-n.manifest.json?v=1&x=2"
UPDATES="https://example.org/app/Warzag.manifest.json?v=1&x=2"
while [ $# -gt 0 ]; do
    case "$1" in
        --app) APP="$2"; shift 2 ;;
        --dmg) DMG="$2"; shift 2 ;;
        --launch) LAUNCH=1; shift ;;
        -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

T="$(cd "$(mktemp -d -t warzag-app-test)" && pwd -P)"
MOUNT=""
APP_PID=""
cleanup() {
    [ -z "$APP_PID" ] || kill -9 "$APP_PID" 2>/dev/null || true
    [ -z "$MOUNT" ] || hdiutil detach -quiet -force "$MOUNT" 2>/dev/null || true
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
refute() {
    local what="$1"; shift
    if "$@" >"$T/out" 2>&1; then fail "$what (unexpectedly succeeded)"; sed 's/^/      /' "$T/out"; else pass "$what"; fi
}

if [ -z "$APP" ] || [ -z "$DMG" ]; then
    # A query string with & checks that the URL reaches install.sh unchanged (& means "the match" to sed).
    "$ROOT/App/make-app.sh" --out "$T/build" --dmg --dist "$T/dist" --dmg-url "https://example.org/Warzag.dmg?v=1&x=2" \
        --feed-url "$FEED" --update-url "$UPDATES" >"$T/make-app.log" 2>&1 \
        || { cat "$T/make-app.log"; echo "FAIL  App/make-app.sh --dmg"; exit 1; }
    pass "App/make-app.sh --dmg"
    check "the app's Info.plist names the runtime feed" test "$(/usr/libexec/PlistBuddy \
        -c 'Print :WarzagRuntimeManifestURL' "$T/build/Warzag.app/Contents/Info.plist")" = "$FEED"
    check "... and the app feed" test "$(/usr/libexec/PlistBuddy \
        -c 'Print :WarzagAppManifestURL' "$T/build/Warzag.app/Contents/Info.plist")" = "$UPDATES"
    check "the app carries this checkout's CHANGELOG.md" \
        cmp "$T/build/Warzag.app/Contents/Resources/CHANGELOG.md" "$ROOT/CHANGELOG.md"
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$T/build/Warzag.app/Contents/Info.plist")"
    ARCHIVE="$T/dist/Warzag-$VERSION.zip"
    check "make-app wrote the update archive Warzag-$VERSION.zip" test -s "$ARCHIVE"
    check "... holding only Warzag.app, with no AppleDouble entries" \
        test -z "$(zipinfo -1 "$ARCHIVE" | grep -v '^Warzag.app/'; zipinfo -1 "$ARCHIVE" | grep '/\._')"
    mkdir "$T/unzipped"
    ditto -x -k --noqtn "$ARCHIVE" "$T/unzipped"
    check "... which unpacks into an app that verifies" "$ROOT/tools/sign/verify.sh" "$T/unzipped/Warzag.app"
    APP="$T/build/Warzag.app"
    DMG="$T/dist/Warzag.dmg"
    check "make-app wrote Warzag.dmg.sha256" test "$(cut -d' ' -f1 "$T/dist/Warzag.dmg.sha256")" = "$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
    check "make-app wrote install.sh with the DMG's checksum and URL" grep -q \
        "DMG_SHA256=\"\${WARZAG_DMG_SHA256:-$(shasum -a 256 "$DMG" | cut -d' ' -f1)}\"" "$T/dist/install.sh"
    check "... and URL" grep -qF 'DMG_URL="${WARZAG_DMG_URL:-https://example.org/Warzag.dmg?v=1&x=2}"' "$T/dist/install.sh"
    check "... and is valid sh" sh -n "$T/dist/install.sh"
    # It must accept the URL it carries. An invalid checksum stops it right after the URL check, so nothing is
    # downloaded.
    check "the release install.sh accepts its own URL" \
        bash -c "WARZAG_DMG_SHA256=not-hex sh '$T/dist/install.sh' 2>&1 | grep -q 'no valid SHA-256'"
    check "... and nothing else in the dist directory" \
        test "$(ls -A "$T/dist" | tr '\n' ' ')" = "Warzag-$VERSION.zip Warzag.dmg Warzag.dmg.sha256 install.sh "
fi
APP="$(cd "$APP" && pwd -P)"
DMG="$(cd "$(dirname "$DMG")" && pwd -P)/$(basename "$DMG")"
SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"

# --- the bundle -----------------------------------------------------------------------------------------------
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist"; }
check "the app verifies against the pinned project certificate" "$ROOT/tools/sign/verify.sh" "$APP"
check "CFBundleIdentifier is com.warzag.app" test "$(plist CFBundleIdentifier)" = com.warzag.app
check "CFBundleName and CFBundleDisplayName are Warzag" test "$(plist CFBundleName)/$(plist CFBundleDisplayName)" = Warzag/Warzag
check "LSMinimumSystemVersion is 15.0" test "$(plist LSMinimumSystemVersion)" = 15.0
check "games category" test "$(plist LSApplicationCategoryType)" = public.app-category.games
check "NSHighResolutionCapable" test "$(plist NSHighResolutionCapable)" = true
check "NSPrincipalClass is NSApplication" test "$(plist NSPrincipalClass)" = NSApplication
check "Contents/MacOS/Warzag and Contents/Helpers/warzagctl are arm64" \
    test "$(lipo -archs "$APP/Contents/MacOS/Warzag")/$(lipo -archs "$APP/Contents/Helpers/warzagctl")" = arm64/arm64
check "the icon is there" test -s "$APP/Contents/Resources/AppIcon.icns"
check "the changelog What's New shows is there, in its format" \
    python3 -I "$ROOT/tools/release/changelog.py" check --file "$APP/Contents/Resources/CHANGELOG.md"
check "warzagctl runs from the bundle" "$APP/Contents/Helpers/warzagctl" version
check "the designated requirement pins the certificate (approvals survive updates)" \
    grep -q 'identifier "com.warzag.app" and certificate root = H"' <(codesign -d -r- "$APP" 2>&1)
check "nested code has an identifier under the app's" \
    grep -q '^Identifier=com.warzag.app.warzagctl$' <(codesign -dv "$APP/Contents/Helpers/warzagctl" 2>&1)
refute "no file in the app names the home folder (no debug map with build paths)" grep -rlF "$HOME/" "$APP"
check "the binaries carry no debug map" test -z "$(nm -ap "$APP/Contents/MacOS/Warzag" "$APP/Contents/Helpers/warzagctl" \
    | awk '$5 == "SO" || $5 == "OSO"')"
refute "make-app.sh refuses a --version that is not numbers and dots" \
    "$ROOT/App/make-app.sh" --version '1.0 beta' --out "$T/bad-version"
# install.sh is piped into sh with the URL inside "${WARZAG_DMG_URL:-...}", and a refusal must come before the build:
# afterwards it would leave a new Warzag.dmg next to an install.sh that still expects the old one.
refute "make-app.sh refuses a --dmg-url that would run code in install.sh" \
    "$ROOT/App/make-app.sh" --dmg --dmg-url 'https://example.org/$(id).dmg' --dist "$T/url-dist" --out "$T/url-out"
refute "make-app.sh refuses a plain http --dmg-url" \
    "$ROOT/App/make-app.sh" --dmg --dmg-url 'http://example.org/Warzag.dmg' --dist "$T/url-dist" --out "$T/url-out"
check "... both before building or writing anything" test ! -e "$T/url-dist" -a ! -e "$T/url-out"
refute "make-app.sh refuses --dmg-url without --dmg" \
    "$ROOT/App/make-app.sh" --dmg-url 'https://example.org/Warzag.dmg' --out "$T/url-out"
# The app only accepts an https feed, so make-app.sh refuses anything else before it builds.
refute "make-app.sh refuses a plain http --feed-url" \
    "$ROOT/App/make-app.sh" --feed-url 'http://example.org/runtime/n/manifest.json' --out "$T/feed-out"
refute "make-app.sh refuses a --feed-url that is not a URL" \
    "$ROOT/App/make-app.sh" --feed-url 'releases/manifest.json' --out "$T/feed-out"
check "... both before building or writing anything" test ! -e "$T/feed-out"
# The app accepts only an https app feed, and a build number orders updates: both checked before building.
refute "make-app.sh refuses a plain http --update-url" \
    "$ROOT/App/make-app.sh" --update-url 'http://example.org/app/Warzag.manifest.json' --out "$T/update-out"
refute "make-app.sh refuses a --build that is not a whole number" \
    "$ROOT/App/make-app.sh" --build '1.2' --out "$T/update-out"
check "... both before building or writing anything" test ! -e "$T/update-out"

# --- the disk image ---------------------------------------------------------------------------------------------
# Gatekeeper rejects a signed image that is not notarized but does not assess an unsigned one; it checks the app.
refute "the disk image itself is not signed" codesign -d "$DMG"
check "hdiutil verify" hdiutil verify -quiet "$DMG"
MOUNT="$T/mount"
mkdir "$MOUNT"
if hdiutil attach -quiet -nobrowse -noautoopen -readonly -mountpoint "$MOUNT" "$DMG" </dev/null; then
    check "the image holds Warzag.app" test -d "$MOUNT/Warzag.app"
    check "the image has an Applications link" test "$(readlink "$MOUNT/Applications")" = /Applications
    check "the app in the image verifies" "$ROOT/tools/sign/verify.sh" "$MOUNT/Warzag.app"
    hdiutil detach -quiet "$MOUNT" && MOUNT=""
else
    fail "hdiutil attach"
fi

# --- launch ---------------------------------------------------------------------------------------------------
if [ "$LAUNCH" = 1 ]; then
    FAKE_HOME="$T/home"
    mkdir -p "$FAKE_HOME"
    REAL_STATE="$HOME/Library/Application Support/Warzag/State/setup.json"
    real_state_before=0
    [ ! -e "$REAL_STATE" ] || real_state_before=1
    open -g -j -F -n --env "CFFIXED_USER_HOME=$FAKE_HOME" --env "HOME=$FAKE_HOME" "$APP"
    for _ in $(seq 1 20); do
        APP_PID="$(pgrep -f "$APP/Contents/MacOS/Warzag" | head -n 1 || true)"
        [ -z "$APP_PID" ] || break
        sleep 0.5
    done
    if [ -n "$APP_PID" ]; then
        pass "open -g -j started the app (pid $APP_PID)"
        sleep 5
        check "it is still running 5 s later" kill -0 "$APP_PID"
        check "it ran first-run setup against the scratch home" \
            test -f "$FAKE_HOME/Library/Application Support/Warzag/State/setup.json"
        kill -TERM "$APP_PID" 2>/dev/null || true
        for _ in $(seq 1 20); do kill -0 "$APP_PID" 2>/dev/null || break; sleep 0.5; done
        if kill -0 "$APP_PID" 2>/dev/null; then fail "it did not quit on SIGTERM"; kill -9 "$APP_PID"; else pass "it quit on SIGTERM"; fi
        APP_PID=""
    else
        fail "open -g -j did not start the app"
    fi
    if [ "$real_state_before" = 0 ]; then
        check "the real ~/Library/Application Support/Warzag was not touched" test ! -e "$REAL_STATE"
    fi
fi

# --- install.sh -------------------------------------------------------------------------------------------------
INSTALL="$ROOT/tools/release/install.sh"
DEST="$T/Applications"
check "install.sh installs from a file:// URL" sh "$INSTALL" --url "file://$DMG" --sha256 "$SHA" --dest "$DEST"
check "the installed app verifies" "$ROOT/tools/sign/verify.sh" "$DEST/Warzag.app"
check "the installed app is not quarantined" test -z "$(xattr -p com.apple.quarantine "$DEST/Warzag.app" 2>/dev/null)"
check "install.sh replaces an existing copy" sh "$INSTALL" --url "file://$DMG" --sha256 "$SHA" --dest "$DEST"
check "... leaving only Warzag.app behind" test "$(ls -A "$DEST")" = Warzag.app
# The swap's second rename fails (a stand-in mv refuses to move the staged copy): the installed copy must come back.
mkdir -p "$T/shim"
cat > "$T/shim/mv" <<'EOF'
#!/bin/sh
case "$1" in *.Warzag.app.installing.*) echo "mv: simulated failure" >&2; exit 1 ;; esac
exec /bin/mv "$@"
EOF
chmod +x "$T/shim/mv"
installed="$(stat -f %i "$DEST/Warzag.app")"
refute "install.sh fails when the new copy cannot be moved into place" \
    env PATH="$T/shim:$PATH" sh "$INSTALL" --url "file://$DMG" --sha256 "$SHA" --dest "$DEST"
check "... and puts the installed copy back" test "$(stat -f %i "$DEST/Warzag.app" 2>/dev/null)" = "$installed"
check "... leaving nothing else behind" test "$(ls -A "$DEST")" = Warzag.app
check "... and it still verifies" "$ROOT/tools/sign/verify.sh" "$DEST/Warzag.app"
rm -rf "$DEST"
check "install.sh takes a relative --dest" bash -c "cd '$T' && sh '$INSTALL' --url 'file://$DMG' --sha256 '$SHA' --dest rel-apps"
cp "$T/out" "$T/relative.log"
check "... and names the absolute path it installed to" grep -qF "Installed $T/rel-apps/Warzag.app" "$T/relative.log"
# A process running from the installed bundle: a script stands in for Warzag, which is never started here. (A copy of
# /bin/sleep would not do: launch constraints kill Apple's binaries when they run from anywhere else.)
printf '#!/bin/sh\ni=0\nwhile [ $i -lt 30 ]; do sleep 1; i=$((i + 1)); done\n' > "$T/rel-apps/Warzag.app/Contents/MacOS/stand-in"
chmod +x "$T/rel-apps/Warzag.app/Contents/MacOS/stand-in"
"$T/rel-apps/Warzag.app/Contents/MacOS/stand-in" &
sleeper=$!
refute "install.sh refuses to replace a running copy" \
    bash -c "cd '$T' && sh '$INSTALL' --url 'file://$DMG' --sha256 '$SHA' --dest rel-apps"
cp "$T/out" "$T/running.log"
check "... and says so" grep -q 'Warzag is running from' "$T/running.log"
kill "$sleeper" 2>/dev/null || true
wait "$sleeper" 2>/dev/null || true
rm -rf "$T/rel-apps"
refute "install.sh refuses a wrong checksum" sh "$INSTALL" --url "file://$DMG" --sha256 "$(printf '%064d' 0)" --dest "$DEST"
check "... and installs nothing" test ! -e "$DEST/Warzag.app"
refute "install.sh refuses a plain http URL" sh "$INSTALL" --url "http://example.org/Warzag.dmg" --sha256 "$SHA" --dest "$DEST"
refute "install.sh refuses to run without a URL" sh "$INSTALL" --sha256 "$SHA" --dest "$DEST"
check "install.sh works piped into sh" bash -c "cat '$INSTALL' | sh -s -- --url 'file://$DMG' --sha256 '$SHA' --dest '$DEST'"
check "... and installed the app" "$ROOT/tools/sign/verify.sh" "$DEST/Warzag.app"
rm -rf "$DEST"
if [ -f "$(dirname "$DMG")/install.sh" ]; then
    check "the release install.sh uses its embedded checksum" \
        env WARZAG_DMG_URL="file://$DMG" WARZAG_INSTALL_DIR="$DEST" sh "$(dirname "$DMG")/install.sh"
    check "... and installed the app" test -d "$DEST/Warzag.app"
fi
exit $failed
