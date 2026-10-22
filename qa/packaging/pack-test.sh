#!/bin/bash
# Tests for tools/release/mkpack.sh and warzag-release on a real game host: a pack built with a scratch Ed25519 key,
# then the cases the app must refuse. Stand-in hosts then show that a failed round trip leaves the output directory
# as it was, that a host naming the builder's home folder is refused (only warned about with --allow-builder-paths),
# that a host whose loader is not arm64 or that does not declare WarzagRuntimeChannel n is refused, that a manifest
# for a public URL takes only the release key the app pins, and that the install check refuses a nested executable
# patched after signing. Packs signed with a scratch key name a .invalid URL, as development packs must.
#
#   qa/packaging/pack-test.sh [--host <Warzag.app>] [--smoke]
#
# Needs the project identity (tools/sign/make-cert.sh), clang, and a host (runtime/n/make-host.sh; default: the main
# checkout's build/n/Warzag.app, only read). The real host is packed with --allow-builder-paths, since a host built
# without the path maps names its builder. --smoke also runs tools/release/smoke-host.sh on the extracted pack.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOST_ARGS=()
SMOKE_ARGS=(--no-smoke)
while [ $# -gt 0 ]; do
    case "$1" in
        --host) HOST_ARGS=(--host "$2"); shift 2 ;;
        --smoke) SMOKE_ARGS=(); shift ;;
        -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

T="$(cd "$(mktemp -d -t warzag-pack-test)" && pwd -P)"
trap 'rm -rf "$T"' EXIT
failed=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; failed=1; }
check() {
    local what="$1"; shift
    if "$@" >"$T/out" 2>&1; then pass "$what"; else fail "$what"; sed 's/^/      /' "$T/out"; fi
}
payload() { # payload <manifest>: the signed manifest's payload, decoded
    python3 -I -c 'import base64,json,sys; print(base64.b64decode(json.load(open(sys.argv[1]))["payload"]).decode())' \
        "$1"
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

swift build --package-path "$ROOT" -c release --product warzag-release >/dev/null
RELEASE="$(swift build --package-path "$ROOT" -c release --show-bin-path)/warzag-release"
FINGERPRINT="$(shasum -a 256 "$HOME/.warzag/signing/warzag-community-code-signing.cer" | cut -d' ' -f1)"

check "warzag-release keygen" "$RELEASE" keygen --out "$T/keys" --name qa
PUBKEY="$("$RELEASE" pubkey --key "$T/keys/qa.ed25519" 2>/dev/null)"
check "mkpack.sh builds, signs, archives and round-trips a pack" "$ROOT/tools/release/mkpack.sh" \
    --allow-builder-paths ${HOST_ARGS[@]+"${HOST_ARGS[@]}"} ${SMOKE_ARGS[@]+"${SMOKE_ARGS[@]}"} \
    --out "$T/dist" --key "$T/keys/qa.ed25519" --serial 5 --expires 2 --url-base https://example.invalid/runtime
cp "$T/out" "$T/mkpack.log"
check "... including the RuntimeInstaller run" grep -q '^install   ok: RuntimeInstaller unpacked Warzag.app' "$T/mkpack.log"
PACK="$(ls "$T"/dist/WarzagRuntime-n-*.aar)"
MANIFEST="${PACK%.aar}.manifest.json"
check "the .sha256 file matches the pack" bash -c "cd '$T/dist' && shasum -a 256 -c '$(basename "$PACK").sha256'"
check "Warzag.app is the archive's first entry" test "$(aa list -i "$PACK" | head -n 1)" = Warzag.app
check "no work directories are left in the output" test "$(ls -A "$T/dist" | grep -c '^\.mkpack')" = 0
check "the manifest names the pack's URL" grep -q "https://example.invalid/runtime/$(basename "$PACK")" \
    <(payload "$MANIFEST")

check "warzag-release verify accepts it" "$RELEASE" verify --manifest "$MANIFEST" --pack "$PACK" --pubkey "$PUBKEY" \
    --signer-sha256 "$FINGERPRINT" --no-install
OTHER_KEY="$("$RELEASE" keygen --out "$T/keys" --name other >/dev/null && "$RELEASE" pubkey --key "$T/keys/other.ed25519" 2>/dev/null)"
refute "another public key is refused" "manifest signed with unknown key" \
    "$RELEASE" verify --manifest "$MANIFEST" --pack "$PACK" --pubkey "$OTHER_KEY" --no-install
python3 -I - "$MANIFEST" "$T/tampered.json" <<'EOF'
import base64, json, sys
envelope = json.load(open(sys.argv[1]))
payload = base64.b64decode(envelope["payload"]).replace(b'"serial":5', b'"serial":6')
envelope["payload"] = base64.b64encode(payload).decode()
json.dump(envelope, open(sys.argv[2], "w"))
EOF
refute "a manifest edited after signing is refused" "manifest signature does not verify" \
    "$RELEASE" verify --manifest "$T/tampered.json" --pack "$PACK" --pubkey "$PUBKEY" --no-install
head -c 1000000 "$PACK" > "$T/truncated.aar"
refute "a truncated pack is refused" "size mismatch" \
    "$RELEASE" verify --manifest "$MANIFEST" --pack "$T/truncated.aar" --pubkey "$PUBKEY" --no-install
check "a manifest pinning another certificate can be signed" "$RELEASE" manifest --pack "$PACK" --version 0.0.1 \
    --serial 9 --expires 1 --url https://example.org/x.aar --key "$T/keys/qa.ed25519" \
    --signer-sha256 "$(printf '%064d' 0)" --out "$T/other-signer.json"
refute "... but the install check refuses the pack signed by the project certificate" "runtime signed by $FINGERPRINT" \
    "$RELEASE" verify --manifest "$T/other-signer.json" --pack "$PACK" --pubkey "$PUBKEY"

aa extract -i "$PACK" -d "$T/x"
check "the extracted host verifies" "$ROOT/tools/sign/verify.sh" "$T/x/Warzag.app" --fingerprint "$FINGERPRINT"
check "nested code has identifiers under com.warzag.gamehost" grep -q '^Identifier=com.warzag.gamehost.lsteamclient$' \
    <(codesign -dv "$T/x/Warzag.app/Contents/lib/wine/aarch64-unix/lsteamclient.so" 2>&1)
printf 'x' >> "$T/x/Warzag.app/Contents/share/wine/wine.inf"
refute "an edited resource fails verify.sh" "FAIL" "$ROOT/tools/sign/verify.sh" "$T/x/Warzag.app" --fingerprint "$FINGERPRINT"
rm -rf "$T/x"
aa extract -i "$PACK" -d "$T/x"
printf 'x' >> "$T/x/Warzag.app/Contents/lib/wine/aarch64-unix/lsteamclient.so"
refute "a modified unixlib fails verify.sh" "lsteamclient.so" \
    "$ROOT/tools/sign/verify.sh" "$T/x/Warzag.app" --fingerprint "$FINGERPRINT"
rm -rf "$T/x"

# --- stand-in hosts: a failed round trip, a nested executable patched after signing ----------------------------------
fake_host() { # fake_host <dir> <C source of Contents/MacOS/wine> [arch]: a minimal Warzag.app with a nested wineserver
    local app="$1/Warzag.app" arch="${3:-arm64}"
    mkdir -p "$app/Contents/MacOS"
    printf '%s\n' "$2" > "$1/wine.c"
    printf 'int main(void) { return 0; }\n' > "$1/wineserver.c"
    clang -arch "$arch" -o "$app/Contents/MacOS/wine" "$1/wine.c"
    clang -arch "$arch" -o "$app/Contents/MacOS/wineserver" "$1/wineserver.c"
    cat > "$app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>wine</string>
<key>CFBundleIdentifier</key><string>com.warzag.qa.standin</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.0.1</string>
<key>WarzagRuntimeChannel</key><string>n</string>
</dict></plist>
EOF
}
fake_host "$T/good" '#include <stdio.h>
int main(void) { puts("wine-qa-stand-in"); return 0; }'
fake_host "$T/bad" 'int main(void) { return 3; }'
fake_host "$T/x86" 'int main(void) { return 0; }' x86_64
fake_host "$T/nokey" 'int main(void) { return 0; }'
/usr/libexec/PlistBuddy -c 'Delete :WarzagRuntimeChannel' "$T/nokey/Warzag.app/Contents/Info.plist"
# A build path under the builder's home folder, like the __FILE__ strings in Wine's DLLs.
mkdir -p "$T/bad/Warzag.app/Contents/Resources"
printf 'assertion failed: %s/build/wine/dlls/x.c\n' "$HOME" > "$T/bad/Warzag.app/Contents/Resources/x.txt"
STANDIN=WarzagRuntime-n-0.0.1
STANDIN_ARGS=(--no-smoke --out "$T/standin-dist" --key "$T/keys/qa.ed25519" --expires 2
              --url-base https://example.invalid/runtime)
standin_outputs() { (cd "$T/standin-dist" && shasum -a 256 "$STANDIN.aar" "$STANDIN.aar.sha256" "$STANDIN.manifest.json"); }
check "mkpack.sh packs a stand-in host" "$ROOT/tools/release/mkpack.sh" --host "$T/good/Warzag.app" \
    "${STANDIN_ARGS[@]}" --serial 7
cp "$T/out" "$T/good.log"
check "... without a word about the build machine" test -z "$(grep 'name the build machine' "$T/good.log")"
before="$(standin_outputs || true)"
refute "mkpack.sh refuses a host that names the builder's home folder" "1 file(s) in" \
    "$ROOT/tools/release/mkpack.sh" --host "$T/bad/Warzag.app" "${STANDIN_ARGS[@]}" --serial 8
refute "mkpack.sh refuses a host whose loader is not arm64" "is x86_64, not arm64-only" \
    "$ROOT/tools/release/mkpack.sh" --host "$T/x86/Warzag.app" "${STANDIN_ARGS[@]}" --serial 8
refute "mkpack.sh refuses a host without WarzagRuntimeChannel" "does not declare WarzagRuntimeChannel n" \
    "$ROOT/tools/release/mkpack.sh" --host "$T/nokey/Warzag.app" "${STANDIN_ARGS[@]}" --serial 8
# Every released app pins the release key, so a manifest for a URL players can reach must be signed with it: refused
# with the repository's own pin (or none), with a stand-in pin of another key, and with no pin at all.
PUBLISHED=(--url-base https://example.org/runtime --serial 8)
refute "mkpack.sh refuses a published URL with a key the app does not pin" \
    "must be signed with the release key the app pins" \
    env -u WARZAG_RELEASE_PUBKEY_FILE \
    "$ROOT/tools/release/mkpack.sh" --host "$T/good/Warzag.app" "${STANDIN_ARGS[@]}" "${PUBLISHED[@]}"
check "... before anything is signed" test -z "$(grep '^==> sign' "$T/out")"
refute "... nor one but the pinned release key" "pins ($T/keys/other.ed25519.pub), not with $T/keys/qa.ed25519" \
    env WARZAG_RELEASE_PUBKEY_FILE="$T/keys/other.ed25519.pub" \
    "$ROOT/tools/release/mkpack.sh" --host "$T/good/Warzag.app" "${STANDIN_ARGS[@]}" "${PUBLISHED[@]}"
refute "... and any published URL while no release key is pinned" "none is pinned here ($T/keys/none.pub" \
    env WARZAG_RELEASE_PUBKEY_FILE="$T/keys/none.pub" \
    "$ROOT/tools/release/mkpack.sh" --host "$T/good/Warzag.app" "${STANDIN_ARGS[@]}" "${PUBLISHED[@]}"
refute "mkpack.sh fails when the packed host's wine does not run" "wine --version failed" \
    "$ROOT/tools/release/mkpack.sh" --allow-builder-paths --host "$T/bad/Warzag.app" "${STANDIN_ARGS[@]}" --serial 8
cp "$T/out" "$T/bad.log"
check "... after warning that the host names the builder" \
    grep -q "warning: 1 file(s) in the host name the build machine" "$T/bad.log"
check "... and leaves the previous pack, checksum and manifest untouched" test "$(standin_outputs || true)" = "$before"
check "... with nothing else in the output directory" \
    test "$(ls -A "$T/standin-dist" | tr '\n' ' ')" = "$STANDIN.aar $STANDIN.aar.sha256 $STANDIN.manifest.json "
check "mkpack.sh packs a stand-in host for a published URL with the pinned release key" \
    env WARZAG_RELEASE_PUBKEY_FILE="$T/keys/qa.ed25519.pub" "$ROOT/tools/release/mkpack.sh" \
    --host "$T/good/Warzag.app" "${STANDIN_ARGS[@]}" --out "$T/published-dist" "${PUBLISHED[@]}"
cp "$T/out" "$T/published.log"
check "... saying the release key comes from WARZAG_RELEASE_PUBKEY_FILE" \
    grep -q "^warning: the release key comes from $T/keys/qa.ed25519.pub" "$T/published.log"
check "... and its manifest names the published URL" grep -q "https://example.org/runtime/$STANDIN.aar" \
    <(payload "$T/published-dist/$STANDIN.manifest.json")

# The code of a nested executable (like the real host's wineserver) patched after signing: its code directory and
# so the bundle's seal are unchanged; the install check must still refuse it.
aa extract -i "$T/standin-dist/$STANDIN.aar" -d "$T/patched"
server="$T/patched/Warzag.app/Contents/MacOS/wineserver"
text="$(otool -l "$server" | awk '/sectname __text/ {found = 1} found && $1 == "offset" {print $2; exit}')"
byte="$(od -An -tu1 -j "$text" -N 1 "$server" | tr -d ' ')"
printf "\\$(printf '%03o' $((255 - byte)))" | dd of="$server" bs=1 seek="$text" conv=notrunc 2>/dev/null
aa archive -D "$T/patched/Warzag.app" -o "$T/patched.aar" -a lzfse -exclude-field uid,gid,flg,btm,ctm,xat,acl
check "a manifest for that pack can be signed" "$RELEASE" manifest --pack "$T/patched.aar" --version 0.0.1 \
    --serial 9 --expires 1 --url https://example.org/patched.aar --key "$T/keys/qa.ed25519" \
    --signer-sha256 "$FINGERPRINT" --out "$T/patched.json"
refute "... but the install check refuses the patched nested executable" "code signature validation failed" \
    "$RELEASE" verify --manifest "$T/patched.json" --pack "$T/patched.aar" --pubkey "$PUBKEY" --signer-sha256 "$FINGERPRINT"
refute "... and so does verify.sh" "Contents/MacOS/wineserver" \
    "$ROOT/tools/sign/verify.sh" "$T/patched/Warzag.app" --fingerprint "$FINGERPRINT"
exit $failed
