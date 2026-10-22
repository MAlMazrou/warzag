#!/bin/bash
# Engine smoke test: boots a scratch prefix with the host and runs Warzag's PE test programs (x86-64 ones under
# FEX), while rosetta-watch (qa/n/rosetta-watch.c) records every process started from the host bundle and whether
# macOS runs it under Rosetta (with a positive control).
#
#   qa/n/smoke.sh [--host <Warzag.app>] [--prefix <dir>] [--steam-full] [--only step[,step...]]
#
# Steps: wineboot  ver  bridge-install  d3d11-dxmt  d3d11-nvext  winhttp  probe-load  [probe-full]
#   wineboot        WINEDLLOVERRIDES='mscoree,mshtml=' wineboot -i with the DXMT overlay (system32 placeholders);
#                   checks HKLM\Software\Microsoft\Wow64\amd64 = libarm64ecfex.dll (wz-n-0004)
#   ver             cmd /c ver (native arm64 cmd.exe)
#   bridge-install  bridge/install-prefix.sh with this host (steam.exe, forwarders, probe, steam.reg)
#   d3d11-dxmt      build/pe/wz-d3d11-smoke.exe --frames 300 on DXMT: d3d11_impl and dxgi_impl must be dxmt
#   identity        (with d3d11-dxmt) how LaunchServices sees that windowed process: "Warzag", com.warzag.gamehost,
#                   this host bundle, executable Contents/MacOS/wine (wz-n-0001/0002, runtime/gamehost/Info.plist.in)
#   d3d11-nvext     the same with DXMT_ENABLE_NVEXT=1: vendor 0x10DE
#   winhttp         build/pe/wz-winhttp-probe.exe: ONE request to DE's origin (see qa/pe/README.md)
#   probe-load      wz-steamprobe.exe --load-only (lsteamclient + the Mac steamclient.dylib, never contacts Steam)
#   probe-full      wz-steamprobe.exe with Steam running (shows "Playing" briefly): only with --steam-full
#   session-end     (always) the prefix's wineserver must exit within 120 s once the last step is done; a hung
#                   server is sampled (hung-wineserver.txt) and killed, and the step fails
# Results: $WARZAG_CACHE/work/n/smoke/<time>/ (results.jsonl, one log per step, rosetta.jsonl). Never prints Steam
# IDs or names.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CACHE="${WARZAG_CACHE:-$HOME/Library/Caches/warzag-build}"
MAIN="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null | sed 's#/\.git$##' || true)"
[ -n "$MAIN" ] && [ -d "$MAIN" ] || MAIN="$ROOT"
HOST="$MAIN/build/n/Warzag.app"
PREFIX="$CACHE/prefixes/n-smoke"
PE="$MAIN/build/pe"
STEAM_FULL=0
ONLY=""

while [ $# -gt 0 ]; do
    case "$1" in
        --host) HOST="$2"; shift 2 ;;
        --prefix) PREFIX="$2"; shift 2 ;;
        --steam-full) STEAM_FULL=1; shift ;;
        --only) ONLY="$2"; shift 2 ;;
        -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

die() { echo "error: $*" >&2; exit 1; }
HOST="$(cd "$HOST" && pwd -P)"
C="$HOST/Contents"
[ -x "$C/MacOS/wine" ] || die "no host at $HOST (runtime/n/make-host.sh)"
[ -f "$PE/wz-d3d11-smoke.exe" ] && [ -f "$PE/wz-winhttp-probe.exe" ] || die "no $PE (make -C qa/pe)"
WATCH="$CACHE/work/n/qa/rosetta-watch"
if [ ! -x "$WATCH" ] || [ "$ROOT/qa/n/rosetta-watch.c" -nt "$WATCH" ]; then
    mkdir -p "$(dirname "$WATCH")"
    /usr/bin/clang -O2 -arch arm64 -o "$WATCH" "$ROOT/qa/n/rosetta-watch.c"
fi

RUN="$CACHE/work/n/smoke/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN" "$PREFIX"
PREFIX="$(cd "$PREFIX" && pwd -P)"
RESULTS="$RUN/results.jsonl"
: > "$RESULTS"

want() { [ -z "$ONLY" ] && return 0; case ",$ONLY," in *",$1,"*) return 0 ;; esac; return 1; }
wine() { "$ROOT/runtime/dev-wine.sh" --host "$HOST" --prefix "$PREFIX" "$@"; }
# The wineserver of this prefix: Wine starts it without arguments in /tmp/.wine-<uid>/server-<dev>-<inode> (hex) of
# the prefix directory, where `wineserver -w`/`-k` clients run too.
prefix_server() {
    local dir s cwd
    dir="$(cd "/tmp/.wine-$(id -u)/server-$(printf '%x' "$(stat -f %d "$PREFIX")")-$(printf '%x' "$(stat -f %i "$PREFIX")")" \
        2>/dev/null && pwd -P)" || return 0
    for s in $(pgrep -x wineserver); do
        case "$(ps -o args= -p "$s" 2>/dev/null)" in *" -"*) continue ;; esac
        cwd="$(lsof -a -d cwd -p "$s" -Fn 2>/dev/null | sed -n 's/^n//p')"
        [ -n "$cwd" ] && [ "$(cd "$cwd" 2>/dev/null && pwd -P)" = "$dir" ] && { echo "$s"; return 0; }
    done
}
# wineserver_wait [seconds]: wait until this prefix's wineserver has exited. One still up after the limit (default
# 120 s) is hung: its stacks go to $RUN/hung-wineserver.txt, it and the prefix's Wine processes (working directory in
# the prefix) are killed, and the function fails.
wineserver_wait() {
    local limit="${1:-120}" pid t=0 srv clients
    WINEPREFIX="$PREFIX" "$C/MacOS/wineserver" -w &
    pid=$!
    while kill -0 "$pid" 2>/dev/null && [ "$t" -lt $((limit * 10)) ]; do sleep 0.1; t=$((t + 1)); done
    if kill -0 "$pid" 2>/dev/null; then
        srv="$(prefix_server)"
        if [ -n "$srv" ]; then
            sample "$srv" 1 -mayDie -file "$RUN/hung-wineserver.txt" > /dev/null 2>&1 || true
            kill -9 "$srv" 2>/dev/null || true
        fi
        clients="$(lsof -d cwd -F pn 2>/dev/null \
            | awk -v pre="$PREFIX/" '/^p/ {p = substr($0, 2)} /^n/ && index(substr($0, 2), pre) == 1 {print p}')"
        [ -z "$clients" ] || kill -9 $clients 2>/dev/null || true
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        return 1
    fi
    wait "$pid"
}

# record <step> <exit> <seconds> <json-or-empty> <verdict> [note]
record() {
    local json="${4:-}"
    [ -n "$json" ] && jq -e . >/dev/null 2>&1 <<<"$json" || json=null
    jq -cn --arg step "$1" --argjson exit "$2" --argjson seconds "$3" --argjson result "$json" \
        --arg verdict "$5" --arg note "${6:-}" \
        '{step: $step, verdict: $verdict, exit: $exit, seconds: $seconds, result: $result, note: $note}' >> "$RESULTS"
    printf '%-15s %-4s exit=%-3s %6.1fs  %s %s\n' "$1" "$5" "$2" "$3" "${4:0:400}" "${6:-}"
}

# timed <step> <command...>: runs the command, stdout to <step>.out, stderr to <step>.log; sets STATUS, SECONDS_TAKEN
timed() {
    local step="$1" start end
    shift
    start="$(perl -MTime::HiRes=time -e 'printf "%.3f", time')"
    set +e
    "$@" > "$RUN/$step.out" 2> "$RUN/$step.log"
    STATUS=$?
    set -e
    end="$(perl -MTime::HiRes=time -e 'printf "%.3f", time')"
    SECONDS_TAKEN="$(awk -v a="$start" -v b="$end" 'BEGIN { printf "%.3f", b - a }')"
}
last_json() { tr -d '\r' < "$RUN/$1.out" | grep '^{' | tail -n 1 || true; }

# identity_poll <out-file> <stop-file>: until the stop file exists, look for a LaunchServices app of this host
# bundle (every engine host has the same bundle ID, so the bundle path decides) and write its record once.
identity_poll() {
    local asn bp
    while [ ! -f "$2" ]; do
        for asn in $(lsappinfo find bundleid=com.warzag.gamehost 2>/dev/null | grep -oE 'ASN:0x[0-9a-f]+-0x[0-9a-f]+'); do
            bp="$(lsappinfo info -only bundlepath "$asn" 2>/dev/null | sed -n 's/^"LSBundlePath"="\(.*\)"$/\1/p' || true)"
            [ "$bp" = "$HOST" ] || continue
            lsappinfo info -only name,bundleid,bundlepath,executablepath "$asn" > "$1" 2>/dev/null
            return 0
        done
        sleep 0.2
    done
}
ls_field() { sed -n "s/^\"$1\"=\"\\(.*\\)\"\$/\\1/p" "$2" 2>/dev/null | head -n 1; }
redact() { sed -E "s#$CACHE#<cache>#g; s#$HOME#~#g; s#$(id -un)#<user>#g"; }   # cache first: it lies in the home

STOP="$RUN/.stop-watch"
"$WATCH" "$C/" "$STOP" 7200 > "$RUN/rosetta.jsonl" &
WATCH_PID=$!
trap 'touch "$STOP"; wait "$WATCH_PID" 2>/dev/null || true' EXIT

{ echo "host:   $HOST"; echo "prefix: $PREFIX"; echo "run:    $RUN"; } | redact
echo "macOS $(sw_vers -productVersion), $(sysctl -n machdep.cpu.brand_string), FEAT_AFP=$(sysctl -n hw.optional.arm.FEAT_AFP 2>/dev/null || echo ?)"

if want wineboot; then
    if [ -f "$PREFIX/system.reg" ]; then
        record wineboot 0 0 "" SKIP "prefix exists"
    else
        timed wineboot env WINEDLLOVERRIDES='mscoree,mshtml=' "$ROOT/runtime/dev-wine.sh" --host "$HOST" \
            --prefix "$PREFIX" --renderer dxmt wineboot -i
        wineserver_wait || STATUS=124
        emu="$(grep -A3 -i '^\[Software\\\\Microsoft\\\\Wow64\\\\amd64\]' "$PREFIX/system.reg" | grep '^@=' || true)"
        ph="$(cd "$PREFIX/drive_c/windows/system32" && ls winemetal.dll nvapi64.dll nvngx.dll d3d11.dll 2>/dev/null | tr '\n' ' ')"
        v=FAIL
        [ "$STATUS" = 0 ] && [ -f "$PREFIX/system.reg" ] && [ "$emu" = '@="libarm64ecfex.dll"' ] && v=PASS
        record wineboot "$STATUS" "$SECONDS_TAKEN" "" "$v" "emulator: $emu; system32: $ph"
    fi
fi

if want ver; then
    timed ver wine cmd /c ver
    out="$(tr -d '\r' < "$RUN/ver.out" | grep -v '^$' | head -n 2 | tr '\n' ' ')"
    v=FAIL; [ "$STATUS" = 0 ] && grep -q 'Windows' "$RUN/ver.out" && v=PASS
    record ver "$STATUS" "$SECONDS_TAKEN" "" "$v" "$out"
fi

if want bridge-install; then
    timed bridge-install "$ROOT/bridge/install-prefix.sh" --prefix "$PREFIX" --host "$HOST"
    v=FAIL; [ "$STATUS" = 0 ] && [ -f "$PREFIX/drive_c/Program Files (x86)/Steam/wz-steamprobe.exe" ] && v=PASS
    record bridge-install "$STATUS" "$SECONDS_TAKEN" "" "$v" "$(tail -n 1 "$RUN/bridge-install.out")"
fi

if want d3d11-dxmt; then
    rm -f "$RUN/.stop-identity" "$RUN/identity.txt"
    identity_poll "$RUN/identity.txt" "$RUN/.stop-identity" &
    IDENTITY_PID=$!
    timed d3d11-dxmt wine --renderer dxmt "$PE/wz-d3d11-smoke.exe" --frames 300
    touch "$RUN/.stop-identity"
    wait "$IDENTITY_PID" 2>/dev/null || true
    j="$(last_json d3d11-dxmt)"
    v=FAIL
    [ "$STATUS" = 0 ] && jq -e '.ok == true and .d3d11_impl == "dxmt" and .dxgi_impl == "dxmt" and .vendor_id == "0x106B"' \
        <<<"$j" >/dev/null 2>&1 && v=PASS
    record d3d11-dxmt "$STATUS" "$SECONDS_TAKEN" "$j" "$v"

    name="$(ls_field LSDisplayName "$RUN/identity.txt")"
    bid="$(ls_field CFBundleIdentifier "$RUN/identity.txt")"
    bpath="$(ls_field LSBundlePath "$RUN/identity.txt")"
    exe="$(ls_field CFBundleExecutablePath "$RUN/identity.txt")"
    # LaunchServices keeps the path a process was started with. Wine starts child processes through ntdll's
    # bin_dir, which build_relative_path does not normalize (lib/wine/../../MacOS/wine): the same
    # file as Contents/MacOS/wine, so compare canonical paths.
    exe_real="$( (cd "$(dirname "$exe")" && pwd -P) 2>/dev/null || true)/$(basename "$exe")"
    v=FAIL
    [ "$name" = Warzag ] && [ "$bid" = com.warzag.gamehost ] && [ "$bpath" = "$HOST" ] && [ "$exe_real" = "$C/MacOS/wine" ] \
        && v=PASS
    record identity 0 0 "" "$v" \
        "name=$name bundleid=$bid bundle=${bpath/#$MAIN\//} executable=${exe#$HOST/} (canonical ${exe_real#$HOST/})"
fi

if want d3d11-nvext; then
    timed d3d11-nvext wine --renderer dxmt-nvext "$PE/wz-d3d11-smoke.exe" --frames 300
    j="$(last_json d3d11-nvext)"
    v=FAIL
    [ "$STATUS" = 0 ] && jq -e '.ok == true and .d3d11_impl == "dxmt" and .dxgi_impl == "dxmt" and .vendor_id == "0x10DE"' \
        <<<"$j" >/dev/null 2>&1 && v=PASS
    record d3d11-nvext "$STATUS" "$SECONDS_TAKEN" "$j" "$v"
fi

if want winhttp; then
    timed winhttp wine "$PE/wz-winhttp-probe.exe"
    j="$(last_json winhttp)"
    v=FAIL; [ "$STATUS" = 0 ] && jq -e '.ok == true' <<<"$j" >/dev/null 2>&1 && v=PASS
    record winhttp "$STATUS" "$SECONDS_TAKEN" "$j" "$v"
fi

PROBE='C:\Program Files (x86)\Steam\wz-steamprobe.exe'
if want probe-load; then
    timed probe-load env WINEDEBUG=+loaddll,+steamclient "$ROOT/runtime/dev-wine.sh" --host "$HOST" \
        --prefix "$PREFIX" --steam "$PROBE" --load-only
    j="$(last_json probe-load)"
    v=FAIL; [ "$STATUS" = 0 ] && jq -e '.steamclient_loaded == true and .ok == true' <<<"$j" >/dev/null 2>&1 && v=PASS
    mods="$(grep -E 'Loaded .*(steamclient64|lsteamclient)\.dll|Loaded host steamclient' "$RUN/probe-load.log" \
        | sed -E 's/.*Loaded (L"[^"]*"|host steamclient from "[^"]*")( at [0-9a-fx]+)?(: [a-z]+)?.*/\1\3/' \
        | sed -E 's#/Users/[^/]+/#~/#' | sort -u | tr '\n' ';')"
    record probe-load "$STATUS" "$SECONDS_TAKEN" "$j" "$v" "$mods"
fi

if [ "$STEAM_FULL" = 1 ] && want probe-full; then
    pgrep -x steam_osx >/dev/null || echo "note: Steam (steam_osx) does not seem to run"
    timed probe-full "$ROOT/runtime/dev-wine.sh" --host "$HOST" --prefix "$PREFIX" --steam "$PROBE"
    j="$(last_json probe-full)"
    v=FAIL
    [ "$STATUS" = 0 ] && jq -e '.ok == true and .logged_on == true and .owns_app == true' <<<"$j" >/dev/null 2>&1 && v=PASS
    record probe-full "$STATUS" "$SECONDS_TAKEN" "$j" "$v"
fi

start="$(perl -MTime::HiRes=time -e 'printf "%.3f", time')"
if wineserver_wait 120; then end_status=0; else end_status=1; fi
end="$(perl -MTime::HiRes=time -e 'printf "%.3f", time')"
waited="$(awk -v a="$start" -v b="$end" 'BEGIN { printf "%.3f", b - a }')"
if [ "$end_status" = 0 ]; then
    record session-end 0 "$waited" "" PASS "the prefix's wineserver exited"
else
    record session-end 1 "$waited" "" FAIL \
        "the wineserver was still up after 120 s: stacks in hung-wineserver.txt; it and the prefix's processes were killed"
fi
touch "$STOP"
wait "$WATCH_PID" && watch_status=0 || watch_status=$?
trap - EXIT
summary="$(tail -n 1 "$RUN/rosetta.jsonl")"
# Every executable the run started from the bundle, with its architectures as the file says.
archs="$(jq -r 'select(.run == true) | .path' "$RUN/rosetta.jsonl" | sort -u | while read -r p; do
    printf '%s=%s ' "${p#$C/}" "$(lipo -archs "$p" 2>/dev/null | tr ' ' '+')"; done)"
foreign="$(jq -r 'select(.run == false) | .path' "$RUN/rosetta.jsonl" | sort -u | tr '\n' ' ')"
v=FAIL; [ "$watch_status" = 0 ] && v=PASS
record rosetta "$watch_status" 0 "$summary" "$v" \
    "executables of the run: $archs${foreign:+; translated processes of other tools at the same time (not part of the run): $foreign}"
echo "results: $RESULTS"
