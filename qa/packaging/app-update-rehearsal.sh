#!/bin/bash
# End-to-end rehearsal of Warzag's own update, without a click and without the installed Warzag. Everything lives in
# a temporary directory:
#
#   1. two builds made by App/make-app.sh with the project identity: 0.0.1 (build 1) and 0.0.2 (build 2, with its
#      update archive); build 1 goes into a scratch home's Applications folder, which counts as ~/Applications because
#      the commands run with CFFIXED_USER_HOME set to that home
#   2. an app manifest for build 2, signed with the DEV key, for a feed served on 127.0.0.1 by python's http.server
#      (only development builds accept plain http)
#   3. `warzagctl app status`, `app check` and `app update --yes` from a development build against the scratch copy:
#      check, download, verify, then build 2's own warzagctl swaps
#   4. the clean failure: a copy macOS will not let Warzag change (a deny-delete ACL) is left as it was, and the
#      checked copy is named for the player to drag into Applications
#   5. only with --launch (it launches background-only processes through Launch Services): the hand-over the app
#      makes. A stand-in Warzag.app (build 1) runs build 2's executable as the update helper (--update-swap) for the
#      probe, starts it again on its own for the swap and quits, both responsible for themselves, as
#      LiveAppUpdateService does; then a background-only build 3 is swapped in the same way and started through
#      Launch Services (no quarantine, so Gatekeeper lets it run)
#
#   qa/packaging/app-update-rehearsal.sh [--launch] [--keep]
#
# Needs the project identity, the DEV key (~/.warzag/keys/dev.ed25519) and clang (--launch). The first run builds the
# app in release mode. --keep keeps the temporary directory.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tools/sign/lib.sh
. "$ROOT/tools/sign/lib.sh"
LAUNCH=0
KEEP=0
while [ $# -gt 0 ]; do
    case "$1" in
        --launch) LAUNCH=1; shift ;;
        --keep) KEEP=1; shift ;;
        -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

T="$(cd "$(mktemp -d -t warzag-app-rehearsal)" && pwd -P)"
H="$T/home"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
SERVER=""
launched=()
cleanup() {
    [ -z "$SERVER" ] || { kill "$SERVER" && wait "$SERVER"; } 2>/dev/null || true
    for app in ${launched[@]+"${launched[@]}"}; do "$LSREGISTER" -u "$app" >/dev/null 2>&1 || true; done
    chmod -R -N "$T" 2>/dev/null || true
    if [ "$KEEP" = 1 ]; then echo "kept $T"; else rm -rf "$T"; fi
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
show() { # show <file>: its lines indented, the home folder as ~ and the temp directory as $T
    sed -e "s#$T#\$T#g" -e "s#$HOME#~#g" -e 's/^/      /' "$1"
}
build_of() { /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$1/Contents/Info.plist"; }

DEV_KEY="$HOME/.warzag/keys/dev.ed25519"
[ -f "$DEV_KEY" ] || wz_die "no DEV key at $DEV_KEY"
[ -f "$WZ_CER" ] || wz_die "no project certificate at $WZ_CER (tools/sign/make-cert.sh)"
FINGERPRINT="$(wz_sha256_of "$WZ_CER")"
mkdir -p "$H/Applications" "$T/feed"

# --- 1. two builds ---------------------------------------------------------------------------------------------
wz_note "App/make-app.sh: Warzag 0.0.1 (build 1) and 0.0.2 (build 2, --dmg)"
check "App/make-app.sh builds Warzag 0.0.1 (build 1)" \
    "$ROOT/App/make-app.sh" --out "$T/v1" --version 0.0.1 --build 1
check "App/make-app.sh builds Warzag 0.0.2 (build 2) with its update archive" \
    "$ROOT/App/make-app.sh" --out "$T/v2" --version 0.0.2 --build 2 --dmg --dist "$T/dist"
[ -f "$T/dist/Warzag-0.0.2.zip" ] || { fail "no update archive in the dist directory"; exit 1; }
check "build 1 is signed by the project certificate" "$ROOT/tools/sign/verify.sh" "$T/v1/Warzag.app" --quiet
ditto "$T/v1/Warzag.app" "$H/Applications/Warzag.app"
check "it is installed in the scratch home's Applications folder" test "$(build_of "$H/Applications/Warzag.app")" = 1

# --- 2. the feed -----------------------------------------------------------------------------------------------
wz_note "development builds of warzagctl and warzag-release; the release warzag-release for a comparison"
swift build --package-path "$ROOT" --product warzagctl >/dev/null
swift build --package-path "$ROOT" --product warzag-release >/dev/null
swift build --package-path "$ROOT" -c release --product warzag-release >/dev/null
swift build --package-path "$ROOT" -c release --product warzagctl >/dev/null
DEV="$(swift build --package-path "$ROOT" --show-bin-path)"
RELEASE_BIN="$(swift build --package-path "$ROOT" -c release --show-bin-path)"
PORT="$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
FEED="http://127.0.0.1:$PORT/Warzag.manifest.json"
cp "$T/dist/Warzag-0.0.2.zip" "$T/feed/"
check "the app manifest for build 2 is signed with the DEV key, for the loopback feed" \
    "$DEV/warzag-release" app-manifest --archive "$T/feed/Warzag-0.0.2.zip" --serial "$(date +%s)" --expires 1 \
    --url "http://127.0.0.1:$PORT/Warzag-0.0.2.zip" --key "$DEV_KEY" --signer-sha256 "$FINGERPRINT" \
    --out "$T/feed/Warzag.manifest.json"
refute "a release build refuses that loopback URL" "archive URL must be https" \
    "$RELEASE_BIN/warzag-release" app-verify --manifest "$T/feed/Warzag.manifest.json" \
    --archive "$T/feed/Warzag-0.0.2.zip" --pubkey "$("$DEV/warzag-release" pubkey --key "$DEV_KEY" 2>/dev/null)"
(cd "$T/feed" && exec python3 -I -m http.server "$PORT" --bind 127.0.0.1) >"$T/server.log" 2>&1 &
SERVER=$!
for _ in $(seq 1 50); do curl -fsS -o /dev/null "$FEED" 2>/dev/null && break; sleep 0.2; done
check "the feed is served on 127.0.0.1" curl -fsS -o /dev/null "$FEED"

# --- 3. check, download, verify, swap --------------------------------------------------------------------------
WZ=(env CFFIXED_USER_HOME="$H" "$DEV/warzagctl" --home "$H")
APP=(--app "$H/Applications/Warzag.app" --feed "$FEED")
check "app status: the installed copy can replace itself where it is" \
    grep -q '^location  can replace itself$' <("${WZ[@]}" app status --app "$H/Applications/Warzag.app")
check "app check finds Warzag 0.0.2 (build 2)" "${WZ[@]}" app check "${APP[@]}"
show "$T/out"
refute "a release build of warzagctl refuses the loopback feed" "--feed must be an https URL" \
    env CFFIXED_USER_HOME="$H" "$RELEASE_BIN/warzagctl" --home "$H" app check "${APP[@]}"
check "app update --yes: download, verify, and build 2's own warzagctl swaps" "${WZ[@]}" app update --yes "${APP[@]}"
cp "$T/out" "$T/update.log"
show "$T/update.log"
check "the installed copy is build 2 now" test "$(build_of "$H/Applications/Warzag.app")" = 2
check "... signed by the project certificate, every file sealed" \
    "$ROOT/tools/sign/verify.sh" "$H/Applications/Warzag.app" --quiet
check "... with nothing left next to it" test "$(ls -A "$H/Applications")" = Warzag.app
check "... and the prepared copy cleared" test ! -e "$H/Library/Caches/Warzag/AppUpdate.noindex/staging"
# The helper writes the home folder as ~ (here the scratch home, CFFIXED_USER_HOME).
check "Warzag.log names each step of the swap, the home folder as ~" \
    grep -q "update: replaced ~/Applications/Warzag.app with Warzag 0.0.2" \
    "$H/Library/Logs/Warzag/Warzag.log"
check "the feed served the manifest and the archive" grep -q 'GET /Warzag-0.0.2.zip' "$T/server.log"
check "app check: up to date now" grep -q 'is up to date' <("${WZ[@]}" app check "${APP[@]}")
check "the serial floor is the manifest's" grep -q '^serial    [0-9]' <("${WZ[@]}" app status --app "$H/Applications/Warzag.app")
if grep -q 'not permitted' "$T/update.log" "$H/Library/Logs/Warzag/Warzag.log"; then
    echo "INFO  App Management: macOS refused a step (see above)"
else
    echo "INFO  App Management: macOS refused nothing in the swap (Warzag replaced itself in ~/Applications)"
fi

# --- 4. the clean failure ----------------------------------------------------------------------------------------
mkdir -p "$H/Applications/Denied"
ditto "$T/v1/Warzag.app" "$H/Applications/Denied/Warzag.app"
chmod +a "everyone deny delete" "$H/Applications/Denied/Warzag.app"
refute "where macOS will not let Warzag change it, nothing changes" "Warzag could not replace itself" \
    "${WZ[@]}" app update --yes --app "$H/Applications/Denied/Warzag.app" --feed "$FEED"
cp "$T/out" "$T/denied.log"
show "$T/denied.log"
check "... the copy there is still build 1" test "$(build_of "$H/Applications/Denied/Warzag.app")" = 1
check "... with nothing next to it" test "$(ls -A "$H/Applications/Denied")" = Warzag.app
check "... and the checked new copy is named for the player" grep -q 'drag it into Applications' "$T/denied.log"
STAGED="$H/Library/Caches/Warzag/AppUpdate.noindex/staging/Warzag.app"
check "... which is there and verifies" "$ROOT/tools/sign/verify.sh" "$STAGED" --quiet
chmod -N "$H/Applications/Denied/Warzag.app"

# --- 5. the hand-over the app makes (--launch) ---------------------------------------------------------------
if [ "$LAUNCH" = 1 ]; then
    cat > "$T/launcher.c" <<'EOF'
// The hand-over Warzag makes to install its update (AppUpdater.install(.afterExit), PosixHelperLauncher): the new
// build's helper probes (argv + --probe, waited for), then starts on its own (argv + --wait-pid <this pid>) in a
// session of its own with /dev/null for stdin, stdout and stderr, both responsible for themselves
// (responsibility_spawnattrs_setdisclaim), and this process quits.
#include <dlfcn.h>
#include <fcntl.h>
#include <spawn.h>
#include <stdio.h>
#include <sys/wait.h>
#include <unistd.h>
extern char **environ;
int main(int argc, char **argv) {
    if (argc < 2) return 64;
    char *probe[argc + 1], *swap[argc + 3], self[32];
    for (int i = 1; i < argc; i++) probe[i - 1] = swap[i - 1] = argv[i];
    probe[argc - 1] = "--probe";
    probe[argc] = NULL;
    pid_t pid;
    int status;
    posix_spawnattr_t attributes;
    posix_spawnattr_init(&attributes);
    int (*disclaim)(posix_spawnattr_t *, int) = dlsym(RTLD_DEFAULT, "responsibility_spawnattrs_setdisclaim");
    if (disclaim) disclaim(&attributes, 1);
    if (posix_spawn(&pid, probe[0], NULL, &attributes, probe, environ) != 0) return 70;
    waitpid(pid, &status, 0);
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) return 1;
    snprintf(self, sizeof self, "%d", getpid());
    swap[argc - 1] = "--wait-pid";
    swap[argc] = self;
    swap[argc + 1] = NULL;
    posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETSID);
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0);
    return posix_spawn(&pid, swap[0], &actions, &attributes, swap, environ) == 0 ? 0 : 70;
}
EOF
    clang -arch arm64 -O1 -o "$T/launcher" "$T/launcher.c"
    background_app() { # background_app <Warzag.app> <version> <build> <program> [helper]: com.warzag.app, no window
        mkdir -p "$1/Contents/MacOS"
        cp "$4" "$1/Contents/MacOS/Warzag"
        if [ -n "${5:-}" ]; then
            mkdir -p "$1/Contents/Helpers"
            cp "$5" "$1/Contents/Helpers/warzagctl"
            strip -S -no_code_signature_warning "$1/Contents/Helpers/warzagctl"
        fi
        cat > "$1/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Warzag</string>
<key>CFBundleIdentifier</key><string>com.warzag.app</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$2</string>
<key>CFBundleVersion</key><string>$3</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>LSBackgroundOnly</key><true/>
</dict></plist>
EOF
        "$ROOT/tools/sign/sign.sh" "$1" >/dev/null
    }
    STANDIN="$H/Applications/Launched/Warzag.app"
    background_app "$STANDIN" 0.0.1 1 "$T/launcher"
    launched+=("$STANDIN")
    mkdir "$T/staged"
    ditto -x -k --noqtn "$T/dist/Warzag-0.0.2.zip" "$T/staged"
    LOG="$H/Library/Logs/Warzag/Warzag.log"
    RECORD="$H/Library/Caches/Warzag/AppUpdate.noindex/swap-result.json"
    rm -f "$RECORD"
    # Launch Services starts it as its own responsible process, as when a player opens Warzag; it never sees this
    # shell's environment, so the helper gets the scratch home explicitly and opens nothing (no --open: build 2 is the
    # real app, which would start against the real home).
    open -n -g -j "$STANDIN" --args "$T/staged/Warzag.app/Contents/MacOS/Warzag" --update-swap --home "$H" \
        --installed "$STANDIN" --staged "$T/staged/Warzag.app" --version 0.0.2 --build 2 --signer "$FINGERPRINT" \
        --log "$LOG"
    for _ in $(seq 1 150); do
        grep -q "update: replaced $STANDIN with" "$LOG" 2>/dev/null && break
        sleep 0.2
    done
    check "the app's hand-over: build 2's own executable, started by the launched app, replaced it once it quit" \
        grep -q "update: replaced $STANDIN with Warzag 0.0.2 (build 2)" "$LOG"
    check "... after its probe, made the same way while the app still ran" \
        grep -q "update: $STANDIN can be replaced; Warzag 0.0.2 (build 2) waits next to it" "$LOG"
    check "... the copy there is build 2 and verifies" "$ROOT/tools/sign/verify.sh" "$STANDIN" --quiet
    check "... with nothing left next to it" test "$(ls -A "$H/Applications/Launched")" = Warzag.app
    for _ in $(seq 1 25); do [ -s "$RECORD" ] && break; sleep 0.2; done
    check "... and the outcome recorded for the Warzag that opens next" grep -q '"result" : "replaced"' "$RECORD"
    grep -F "$STANDIN" "$LOG" > "$T/launched.log" || true
    show "$T/launched.log"

    # The new Warzag opens: a bundle the helper put in place starts through Launch Services, not quarantined, so
    # Gatekeeper lets it. A background-only stand-in of build 3, which leaves a mark when it starts, replaces another
    # launched stand-in and is opened with open -n by its path (the helper's own --open could bring a running Warzag
    # forward instead).
    MARK="$T/opened.txt"
    printf '#include <stdio.h>\nint main(void) { FILE *f = fopen("%s", "w"); if (f) { fputs("opened\\n", f); fclose(f); } return 0; }\n' \
        "$MARK" > "$T/opened.c"
    clang -arch arm64 -O1 -o "$T/opened" "$T/opened.c"
    background_app "$T/v3/Warzag.app" 0.0.3 3 "$T/opened" "$RELEASE_BIN/warzagctl"
    OPENED="$H/Applications/Opened/Warzag.app"
    background_app "$OPENED" 0.0.1 1 "$T/launcher"
    launched+=("$OPENED")
    open -n -g -j "$OPENED" --args "$T/v3/Warzag.app/Contents/Helpers/warzagctl" --home "$H" app swap \
        --installed "$OPENED" --staged "$T/v3/Warzag.app" --version 0.0.3 --build 3 --signer "$FINGERPRINT" --log "$LOG"
    for _ in $(seq 1 150); do
        grep -q "update: replaced $OPENED with" "$LOG" 2>/dev/null && break
        sleep 0.2
    done
    check "a second hand-over put build 3 in place" grep -q "update: replaced $OPENED with Warzag 0.0.3 (build 3)" "$LOG"
    check "... without a quarantine attribute anywhere" test -z "$(xattr -r "$OPENED" | grep com.apple.quarantine)"
    open -n -g -j "$OPENED"
    for _ in $(seq 1 50); do [ -s "$MARK" ] && break; sleep 0.2; done
    check "... and it starts through Launch Services (Gatekeeper lets the swapped-in app run)" test -s "$MARK"
fi
exit $failed
