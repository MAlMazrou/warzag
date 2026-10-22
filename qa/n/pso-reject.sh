#!/bin/bash
# Regression test for wz-n-dxmt-0002: a pipeline that Metal rejects must not leave a freed NSError in a DXMT pipeline
# worker's autorelease pool, so the workers exit cleanly when the game releases its device.
#
#   qa/n/pso-reject.sh [--host <Warzag.app>] [--pipelines N] [--frames N] [--highwater] [--no-zombies] [--keep]
#                      [--timeout <seconds>]
#
# Builds qa/pe/d3d11-pso-reject, boots a throwaway prefix with the DXMT overlay and runs the program once with a hard
# timeout, NSZombieEnabled=YES and DXMT_LOG_LEVEL=trace. The program draws with a vertex/pixel shader pair Metal
# refuses to link, then releases the device and waits until DXMT's worker threads have exited.
#   PASS   the result line says ok, d3d11 is DXMT, the draw was dropped ("Failed to create PSO"), a second pair that
#          links rendered, and no process reported a message sent to a deallocated instance or an exiting-thread fault
#   FAIL   a zombie message (an over-release), a wz-n-0011 exiting-thread fault (the same without zombies), a hang, a
#          failed stage, or the pair that links not rendering
#   ERROR  the run did not exercise the bug (not DXMT, or the pipeline linked), or setup failed
# --pipelines N   N rejected pipelines (different blend states), default 1
# --frames N      first present N frames to a window (DXMT's per-Present display query runs on the program's thread)
# --highwater     also set OBJC_PRINT_POOL_HIGHWATER=YES and print each thread's highest autorelease pool mark; a thread
#                 in DXMT code above objc's 256-object report threshold fails the run (a leak; try --frames 120)
# --no-zombies    run without NSZombieEnabled (an over-release then shows as a fault, or not at all)
# --keep          keep the throwaway folder
#
# Exit: 0 = PASS, 1 = FAIL, 2 = ERROR (setup, or the run did not exercise the bug).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CACHE="${WARZAG_CACHE:-$HOME/Library/Caches/warzag-build}"
CACHE="${CACHE%/}"
MAIN="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null | sed 's#/\.git$##' || true)"
[ -n "$MAIN" ] && [ -d "$MAIN" ] || MAIN="$ROOT"
HOST="$MAIN/build/n/Warzag.app"
KEEP=0
TIMEOUT=120
PIPELINES=1
FRAMES=0
HIGHWATER=0
ZOMBIES=1

while [ $# -gt 0 ]; do
    case "$1" in
        --host) HOST="$2"; shift 2 ;;
        --pipelines) PIPELINES="$2"; shift 2 ;;
        --frames) FRAMES="$2"; shift 2 ;;
        --highwater) HIGHWATER=1; shift ;;
        --no-zombies) ZOMBIES=0; shift ;;
        --keep) KEEP=1; shift ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
        -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

die() { echo "error: $*" >&2; exit 2; }
[[ "$PIPELINES" =~ ^[0-9]+$ ]] && [ "$PIPELINES" -ge 1 ] && [ "$PIPELINES" -le 960 ] || die "--pipelines takes 1-960"
[[ "$FRAMES" =~ ^[0-9]+$ ]] && [ "$FRAMES" -le 100000 ] || die "--frames takes 0-100000"
[[ "$TIMEOUT" =~ ^[0-9]+$ ]] && [ "$TIMEOUT" -ge 1 ] || die "--timeout takes seconds"
[ "$(uname -m)" = arm64 ] || die "the engine runs on Apple silicon only"
HOST="$(cd "$HOST" 2>/dev/null && pwd -P)" || die "no host bundle at $HOST (runtime/n/make-host.sh)"
C="$HOST/Contents"
[ -x "$C/MacOS/wine" ] && [ -x "$C/MacOS/wineserver" ] || die "no wine/wineserver in $HOST"
[ -f "$C/renderers/dxmt/aarch64-windows/d3d11.dll" ] || die "no DXMT overlay in $HOST"

redact() { sed -E "s#$CACHE#<cache>#g; s#$HOME#~#g; s#$(id -un)#<user>#g"; }   # cache first: it lies in the home

OUT="$CACHE/work/n/pso-reject"
EXE="$OUT/wz-d3d11-pso-reject.exe"
mkdir -p "$OUT"
echo "==> build the test program (make -C qa/pe)"
make -s -C "$ROOT/qa/pe" OUT="$OUT" "$EXE" 2>&1 | redact
[ -f "$EXE" ] || die "the test program did not build"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/wz-pso-reject.XXXXXX")"
PREFIX="$WORKDIR/pfx"
LOGDIR="$WORKDIR/dxmt-log"
mkdir -p "$PREFIX" "$LOGDIR"

cleanup() {
    WINEPREFIX="$PREFIX" "$C/MacOS/wineserver" -k >/dev/null 2>&1 || true
    [ "$KEEP" = 1 ] || rm -rf "$WORKDIR"
}
trap cleanup EXIT

# run_limited <seconds> <cmd...>: as in qa/n/exit-hang.sh (exit status, 128+N for signal N, 124 on timeout).
run_limited() {
    local t="$1"; shift
    perl -e '
        my $t = shift;
        my $pid = fork();
        if (!defined $pid) { die "fork: $!" }
        if ($pid == 0) { exec @ARGV or die "exec: $!" }
        my $killed = 0;
        $SIG{ALRM} = sub { $killed = 1; kill "KILL", $pid; };
        alarm $t;
        waitpid($pid, 0);
        my $st = $?;
        exit(124) if $killed;
        exit($st >> 8 ? $st >> 8 : ($st & 127 ? 128 + ($st & 127) : 0));
    ' "$t" "$@"
}

count() { grep -c -- "$1" "$2" 2>/dev/null || true; }   # count <pattern> <file>: matching lines (0 when none)

echo "==> boot a throwaway prefix (DXMT overlay)"
echo "    prefix: $PREFIX" | redact
if ! run_limited 600 /usr/bin/env WINEDLLOVERRIDES='mscoree,mshtml=' "$ROOT/runtime/dev-wine.sh" --host "$HOST" \
        --prefix "$PREFIX" --renderer dxmt wineboot -i > "$WORKDIR/wineboot.log" 2>&1; then
    tail -5 "$WORKDIR/wineboot.log" | redact || true
    die "wineboot failed or timed out"
fi
run_limited 120 /usr/bin/env WINEPREFIX="$PREFIX" "$C/MacOS/wineserver" -w >/dev/null 2>&1 || true
WINEPREFIX="$PREFIX" "$C/MacOS/wineserver" -k >/dev/null 2>&1 || true
[ -f "$PREFIX/system.reg" ] || die "prefix did not boot"

ENVS=(DXMT_LOG_LEVEL=trace "DXMT_LOG_PATH=Z:$LOGDIR/")
[ "$ZOMBIES" = 1 ] && ENVS+=(NSZombieEnabled=YES)
[ "$HIGHWATER" = 1 ] && ENVS+=(OBJC_PRINT_POOL_HIGHWATER=YES)
echo
echo "==> run wz-d3d11-pso-reject.exe --pipelines $PIPELINES --frames $FRAMES (timeout ${TIMEOUT}s; ${ENVS[*]})" \
    | sed -E 's#DXMT_LOG_PATH=[^ ;)]*#DXMT_LOG_PATH=<throwaway>#' | redact
set +e
run_limited "$TIMEOUT" /usr/bin/env "${ENVS[@]}" "$ROOT/runtime/dev-wine.sh" --host "$HOST" --prefix "$PREFIX" \
    --renderer dxmt "$EXE" --pipelines "$PIPELINES" --frames "$FRAMES" > "$WORKDIR/test.out" 2> "$WORKDIR/test.err"
STATUS=$?
set -e
WINEPREFIX="$PREFIX" "$C/MacOS/wineserver" -k >/dev/null 2>&1 || true
cat "$LOGDIR"/*.log > "$WORKDIR/dxmt.log" 2>/dev/null || : > "$WORKDIR/dxmt.log"

RESULT="$(tr -d '\r' < "$WORKDIR/test.out" | grep '^{' | tail -n 1 || true)"
field() { [ -n "$RESULT" ] && jq -r "$1" <<<"$RESULT" 2>/dev/null || echo ""; }
ZOMBIE_LINES="$(count 'message sent to deallocated instance' "$WORKDIR/test.err")"
# Without zombies an over-release is a fault in objc_release under a pthread TSD destructor, which wz-n-0011 reports.
EXIT_FAULTS="$(count 'warzag\[wz-n-0011\]: exiting-thread fault' "$WORKDIR/test.err")"
EXIT_CRASHES="$(count 'warzag\[wz-n-0011\]: .*crashing' "$WORKDIR/test.err")"
# DXMT logs to stderr and, with DXMT_LOG_PATH, to its log files: count the files' lines first.
REJECTED="$(count 'Failed to create PSO' "$WORKDIR/dxmt.log")"
[ "$REJECTED" != 0 ] || REJECTED="$(count 'Failed to create PSO' "$WORKDIR/test.err")"
OK="$(field '.ok')"
IMPL="$(field '.d3d11_impl')"
DROPPED="$(field '.draw_dropped')"
LINKED="$(field '.linked_drawn')"
STAGE="$(field '.stage // empty')"

echo "--- result line ---"
if [ -n "$RESULT" ]; then echo "$RESULT" | redact; else echo "(none)"; fi
echo "--- exit status $STATUS; zombie messages $ZOMBIE_LINES; DXMT 'Failed to create PSO' lines $REJECTED ---"
grep -m 3 -- 'message sent to deallocated instance' "$WORKDIR/test.err" | sed -E 's/0x[0-9a-f]+/<hex>/g' | redact || true
cat "$WORKDIR/dxmt.log" "$WORKDIR/test.err" | grep -m 1 -- 'Failed to create PSO' | cut -c1-240 | redact || true
grep -E 'warzag\[wz-n-0011\]' "$WORKDIR/test.err" | sed -E 's/0x[0-9a-f]+/<hex>/g' | sort | uniq -c | head -3 | redact || true
if [ "$HIGHWATER" = 1 ]; then
    # Every Wine process writes to this stderr; each objc line carries its pid. Per process and thread: the highest
    # mark, and where the reporting pool was popped (winemetal.so when DXMT code is on the stack, else the first
    # library past objc, CoreFoundation and Foundation).
    echo "--- autorelease pool high-water marks (objc reports a pop that finds 256 objects more than before) ---"
    MARKS="$(awk '
        function pid_of(line) { match(line, /objc\[[0-9]+\]/); return substr(line, RSTART + 5, RLENGTH - 6) }
        /POOL HIGHWATER: new high water mark of [0-9]+ pending releases for thread/ {
            p = pid_of($0)
            n = $0; sub(/.*new high water mark of /, "", n); sub(/ .*/, "", n)
            t = $0; sub(/.*for thread /, "", t); sub(/:.*/, "", t)
            key[p] = p " " t
            take[p] = (n + 0 > max[key[p]] + 0)
            if (take[p]) { max[key[p]] = n; via[key[p]] = "" }
            next
        }
        /POOL HIGHWATER: +[0-9]+ +[^ ]+ +0x/ {
            p = pid_of($0)
            if (!take[p]) next
            lib = $5
            if (lib == "winemetal.so") via[key[p]] = "winemetal.so"
            else if (via[key[p]] == "" && lib !~ /^(libobjc\.A\.dylib|CoreFoundation|Foundation)$/) via[key[p]] = lib
        }
        END { for (k in max) { split(k, f, " "); printf "%d %s %s %s\n", max[k], f[1], f[2], (via[k] == "" ? "?" : via[k]) } }
    ' "$WORKDIR/test.err" | sort -rn || true)"
    if [ -n "$MARKS" ]; then
        echo "$MARKS" | awk '{ printf "    %6d objects  pid %s thread %s  pool popped in %s\n", $1, $2, $3, $4 }'
    else
        echo "    none (no thread held more than 256 autoreleased objects at a pool pop)"
    fi
    DXMT_MARKS="$(awk '$4 == "winemetal.so"' <<<"$MARKS" | grep -c . || true)"
    echo "    threads in DXMT code (winemetal.so on the stack) above 256 objects: $DXMT_MARKS"
fi

if [ "$ZOMBIE_LINES" -gt 0 ]; then
    VERDICT=FAIL; DETAIL="over-release: $ZOMBIE_LINES message(s) sent to a deallocated instance (exit status $STATUS)"
elif [ "$EXIT_FAULTS" -gt 0 ] || [ "$EXIT_CRASHES" -gt 0 ]; then
    VERDICT=FAIL
    DETAIL="$EXIT_FAULTS fault(s) and $EXIT_CRASHES fatal signal(s) in exiting threads' TSD destructors (wz-n-0011 lines; exit status $STATUS)"
elif [ "$STATUS" = 124 ]; then
    VERDICT=FAIL; DETAIL="hang: still running after ${TIMEOUT}s"
elif [ -z "$RESULT" ]; then
    VERDICT=FAIL; DETAIL="no result line (exit status $STATUS): the process died, most likely while releasing the device"
elif [ "$STATUS" != 0 ] || [ "$OK" != true ]; then
    VERDICT=FAIL; DETAIL="exit status $STATUS, stage ${STAGE:-?}"
elif [ "$IMPL" != dxmt ]; then
    VERDICT=ERROR; DETAIL="d3d11 is '$IMPL', not DXMT: nothing was tested"
elif [ "$HIGHWATER" = 1 ] && [ "${DXMT_MARKS:-0}" -gt 0 ]; then
    VERDICT=FAIL; DETAIL="leak: $DXMT_MARKS thread(s) in DXMT code held more than 256 autoreleased objects at a pool pop"
elif [ "$LINKED" != true ]; then
    VERDICT=FAIL; DETAIL="the pipeline that links did not render the vertex shader's red (linked_drawn=${LINKED:-missing}): a working pipeline is broken"
elif [ "$DROPPED" != true ] || [ "$REJECTED" = 0 ]; then
    VERDICT=ERROR; DETAIL="Metal did not reject the pipeline (draw_dropped=$DROPPED, $REJECTED 'Failed to create PSO'): the test no longer exercises the bug"
else
    VERDICT=PASS; DETAIL="$PIPELINES rejected pipeline(s) and one that links (it rendered), the device's workers exited cleanly"
fi
[ "$ZOMBIES" = 1 ] || DETAIL="$DETAIL (without NSZombieEnabled)"
echo
echo "==> host: $HOST" | redact
echo "RESULT: $VERDICT -- $DETAIL"
case "$VERDICT" in PASS) exit 0 ;; FAIL) exit 1 ;; *) exit 2 ;; esac
