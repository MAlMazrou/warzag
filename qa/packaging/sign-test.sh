#!/bin/bash
# Tests for tools/sign/{make-cert,sign,verify}.sh against a scratch identity, keychain and bundle.
#
#   qa/packaging/sign-test.sh
#
# Never touches the real project identity: the scratch keychain lives in a temporary directory, its password comes
# from WARZAG_SIGNING_PASSWORD (nothing is written to the login keychain), and the identity has its own name. Needs
# clang (Xcode command line tools) to build the test Mach-O files.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SIGN="$ROOT/tools/sign"
T="$(mktemp -d -t warzag-sign-test)"
export WARZAG_SIGN_KEYCHAIN="$T/test-signing.keychain-db"
export WARZAG_SIGNING_DIR="$T/signing"
export WARZAG_SIGNING_PASSWORD="warzag-test-$RANDOM-$RANDOM"
export WARZAG_SIGN_IDENTITY="Warzag QA Test Signing"
cleanup() {
    # The scratch keychain must never stay on the user's search list.
    (. "$SIGN/lib.sh" && wz_detach_keychain) || true
    security delete-keychain "$WARZAG_SIGN_KEYCHAIN" 2>/dev/null || true
    rm -rf "$T"
}
trap cleanup EXIT

failed=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; failed=1; }
check() { # check <description> <command...>
    local what="$1"; shift
    if "$@" >"$T/out" 2>&1; then pass "$what"; else fail "$what"; sed 's/^/      /' "$T/out"; fi
}
refute() { # refute <description> <command...>: the command must fail
    local what="$1"; shift
    if "$@" >"$T/out" 2>&1; then fail "$what (unexpectedly succeeded)"; sed 's/^/      /' "$T/out"; else pass "$what"; fi
}
search_list() { security list-keychains -d user; }
before="$(search_list)"

# --- identity -----------------------------------------------------------------------------------------------------
"$SIGN/make-cert.sh" >"$T/first.txt" 2>&1 || { cat "$T/first.txt"; echo "FAIL  make-cert.sh (first run)"; exit 1; }
fp="$(awk '/^SHA-256/ {print $2}' "$T/first.txt")"
sha1="$(awk '/^SHA-1/ {print $2}' "$T/first.txt")"
check "make-cert creates an identity and proves codesign signs with it" grep -q '^check: codesign signed' "$T/first.txt"
check "the .p12 backup and .cer are mode 600" \
    test "$(stat -f %Lp "$WARZAG_SIGNING_DIR/warzag-community-code-signing.p12")" = 600 \
    -a "$(stat -f %Lp "$WARZAG_SIGNING_DIR/warzag-community-code-signing.cer")" = 600
check "the SHA-256 printed is the .cer's" \
    test "$(shasum -a 256 "$WARZAG_SIGNING_DIR/warzag-community-code-signing.cer" | cut -d' ' -f1)" = "$fp"
check "the identity is untrusted (no trust settings were added)" \
    grep -q "$sha1 \"$WARZAG_SIGN_IDENTITY\" (CSSMERR_TP_NOT_TRUSTED)" <(security find-identity -p codesigning "$WARZAG_SIGN_KEYCHAIN")
"$SIGN/make-cert.sh" --no-check >"$T/second.txt" 2>&1
check "a second run keeps the same certificate" grep -q "^SHA-256   $fp\$" "$T/second.txt"
refute "a second run generates nothing" grep -q 'generate' "$T/second.txt"
security delete-keychain "$WARZAG_SIGN_KEYCHAIN"
"$SIGN/make-cert.sh" --no-check >"$T/restore.txt" 2>&1
check "a lost keychain is restored from the .p12 with the same certificate" grep -q "^SHA-256   $fp\$" "$T/restore.txt"
check "the restore imports, it does not generate" grep -q 'import .*warzag-community-code-signing.p12' "$T/restore.txt"
CER="$WARZAG_SIGNING_DIR/warzag-community-code-signing.cer"
cp "$CER" "$T/cer.bak"
printf x >> "$CER"
refute "a .cer that is not the keychain's certificate is refused" "$SIGN/make-cert.sh" --no-check
cp "$T/cer.bak" "$CER"

# --- a bundle shaped like the game host -----------------------------------------------------------------------
B="$T/Test.app"
mkdir -p "$B/Contents/MacOS" "$B/Contents/lib/wine/aarch64-unix" "$B/Contents/Helpers" "$B/Contents/Resources"
cat > "$T/main.c" <<'EOF'
int main(void) { return 0; }
EOF
cat > "$T/lib.c" <<'EOF'
int warzag_test_value(void) { return 42; }
EOF
clang -arch arm64 -o "$B/Contents/MacOS/Test" "$T/main.c"
clang -arch arm64 -o "$B/Contents/Helpers/helper" "$T/main.c"
clang -arch arm64 -dynamiclib -install_name @rpath/libtest.1.dylib -o "$B/Contents/lib/libtest.1.dylib" "$T/lib.c"
ln -s libtest.1.dylib "$B/Contents/lib/libtest.dylib"
clang -arch arm64 -bundle -o "$B/Contents/lib/wine/aarch64-unix/unixlib.so" "$T/lib.c"
printf 'not code\n' > "$B/Contents/Resources/data.txt"
cat > "$B/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Test</string>
<key>CFBundleIdentifier</key><string>com.warzag.qa.signtest</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
EOF

check "sign.sh signs the bundle with the project identity" "$SIGN/sign.sh" "$B"
check "verify.sh accepts it with the identity's fingerprint" "$SIGN/verify.sh" "$B" --fingerprint "$fp"
check "verify.sh with 'any' accepts one consistent signer" "$SIGN/verify.sh" "$B" --fingerprint any
refute "verify.sh rejects another fingerprint" "$SIGN/verify.sh" "$B" --fingerprint "$(printf '%064d' 0)"
refute "verify.sh rejects 'adhoc' for a certificate signature" "$SIGN/verify.sh" "$B" --fingerprint adhoc
for f in Contents/MacOS/Test Contents/Helpers/helper Contents/lib/libtest.1.dylib Contents/lib/wine/aarch64-unix/unixlib.so; do
    check "$f: Authority is the identity" grep -q "^Authority=$WARZAG_SIGN_IDENTITY\$" <(codesign -dv --verbose=2 "$B/$f" 2>&1)
    check "$f: no hardened runtime" grep -q 'flags=0x0(none)' <(codesign -dv "$B/$f" 2>&1)
done
check "the bundle's identifier comes from Info.plist" grep -q '^Identifier=com.warzag.qa.signtest$' <(codesign -dv "$B" 2>&1)
check "the signed main executable runs" "$B/Contents/MacOS/Test"
check "the keychain search list is as before" test "$(search_list)" = "$before"

cp "$B/Contents/Resources/data.txt" "$T/data.bak"
printf 'tampered\n' > "$B/Contents/Resources/data.txt"
refute "verify.sh rejects a modified resource" "$SIGN/verify.sh" "$B" --fingerprint "$fp"
cp "$T/data.bak" "$B/Contents/Resources/data.txt"
printf 'extra\n' > "$B/Contents/Resources/extra.txt"
refute "verify.sh rejects an added file" "$SIGN/verify.sh" "$B" --fingerprint "$fp"
rm "$B/Contents/Resources/extra.txt"
check "verify.sh accepts the bundle again once restored" "$SIGN/verify.sh" "$B" --fingerprint "$fp"
codesign --force --sign - "$B/Contents/lib/libtest.1.dylib" 2>/dev/null
refute "verify.sh rejects one library re-signed by someone else" "$SIGN/verify.sh" "$B" --fingerprint "$fp"

check "sign.sh --identity adhoc" "$SIGN/sign.sh" "$B" --identity adhoc
check "verify.sh --fingerprint adhoc accepts it" "$SIGN/verify.sh" "$B" --fingerprint adhoc
refute "verify.sh rejects ad hoc when the identity is expected" "$SIGN/verify.sh" "$B" --fingerprint "$fp"
check "re-signing with the identity replaces every ad-hoc signature" "$SIGN/sign.sh" "$B"
check "... and verifies" "$SIGN/verify.sh" "$B" --fingerprint "$fp"

check "sign.sh --identity adhoc (again)" "$SIGN/sign.sh" "$B" --identity adhoc
codesign --force --sign - --options runtime "$B/Contents/Helpers/helper" 2>/dev/null
codesign --force --sign - "$B" 2>/dev/null
refute "verify.sh rejects the hardened runtime" "$SIGN/verify.sh" "$B" --fingerprint adhoc
cp "$T/out" "$T/why"
check "... and says why" grep -q 'Contents/Helpers/helper: signed with the hardened runtime' "$T/why"

# --- one signing run at a time per user, whatever its signing directory -------------------------------------------
# Every run edits the user's keychain search list, so this test's runs (scratch signing directory) must wait for a
# real one. Stand-in for the real run: a process holding, for 4 s, the lock a run with the default settings takes.
lock="$(env -u WARZAG_SIGN_KEYCHAIN -u WARZAG_SIGNING_DIR -u WARZAG_SIGNING_PASSWORD -u WARZAG_SIGN_IDENTITY \
    bash -c '. "$1" && printf "%s" "${WZ_SIGN_LOCK:-}"' _ "$SIGN/lib.sh")"
cp /usr/bin/true "$T/probe"
/usr/bin/lockf -k "$lock" sleep 4 &
holder=$!
sleep 1
TIMEFORMAT=%R
elapsed="$( { time "$SIGN/sign.sh" "$T/probe" >"$T/lock-run.txt" 2>&1; } 2>&1 )" || true
wait "$holder" || true
check "sign.sh waits for another user-wide signing run (it took ${elapsed}s)" awk -v e="$elapsed" 'BEGIN { exit !(e >= 2) }'
check "... and then signs" grep -q "^Authority=$WARZAG_SIGN_IDENTITY\$" <(codesign -dv --verbose=2 "$T/probe" 2>&1)

check "the keychain search list is still as before" test "$(search_list)" = "$before"
exit $failed
