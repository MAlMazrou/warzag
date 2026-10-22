#!/bin/bash
# Regression test for wz-n-0011: a Wine thread whose pthread TSD destructor faults while it exits must still finish
# exiting, and a deliberate stop (abort(), __builtin_trap()) in such a destructor must still end the process.
#
#   qa/n/exit-hang.sh [--host <Warzag.app>] [--mode <mode>]... [--keep] [--timeout <seconds>]
#
# Builds exit-hang/exit-thread.c (a Windows console program) and exit-hang/pool-fault.m (a DYLD_INSERT_LIBRARIES
# dylib that arms a fault in a TSD destructor of the program's Wine threads), boots a throwaway prefix without the
# injection, then runs the program with it once per mode (default: all, in this order):
#   pool     objc's hot-page destructor drains a pool page and -release faults (Wine's keys cleared; Warframe's case)
#   elision  objc's deferred-autorelease destructor releases a faulting object (Wine's keys cleared)
#   tlv      a faulting C++ thread_local destructor, run while the thread's Wine data is still set
#   align    an alignment fault in the pool drain
#   abort    -release calls abort()
#   trap     -release executes __builtin_trap()
#   guard    a native thread (no Wine thread data) reads a Windows PAGE_GUARD page
# pool, elision, tlv and align pass with ALL OK and at least 3 faults redirected by the engine; abort and trap pass
# when a signal kills the process after the engine's "crashing" line (leaving a crash report for "wine"); guard
# passes with ALL OK. --keep keeps the throwaway prefix.
#
# Exit: 0 = PASS (every mode), 1 = FAIL (some mode), 2 = setup error (including an injection that did not act).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CACHE="${WARZAG_CACHE:-$HOME/Library/Caches/warzag-build}"
CACHE="${CACHE%/}"
MAIN="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null | sed 's#/\.git$##' || true)"
[ -n "$MAIN" ] && [ -d "$MAIN" ] || MAIN="$ROOT"
HOST="$MAIN/build/n/Warzag.app"
KEEP=0
TIMEOUT=60
ALL_MODES=(pool elision tlv align abort trap guard)
MODES=()

while [ $# -gt 0 ]; do
    case "$1" in
        --host) HOST="$2"; shift 2 ;;
        --mode) MODES+=("$2"); shift 2 ;;
        --keep) KEEP=1; shift ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
        -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

die() { echo "error: $*" >&2; exit 2; }
[ ${#MODES[@]} -eq 0 ] && MODES=("${ALL_MODES[@]}")
for m in "${MODES[@]}"; do
    case " ${ALL_MODES[*]} " in *" $m "*) ;; *) die "unknown mode: $m (modes: ${ALL_MODES[*]})" ;; esac
done
[ "$(uname -m)" = arm64 ] || die "the engine runs on Apple silicon only"
HOST="$(cd "$HOST" 2>/dev/null && pwd -P)" || die "no host bundle at $HOST (runtime/n/make-host.sh)"
C="$HOST/Contents"
WINE="$C/MacOS/wine"
WINESERVER="$C/MacOS/wineserver"
[ -x "$WINE" ] && [ -x "$WINESERVER" ] || die "no wine/wineserver in $HOST"

LLVM_MINGW_VERSION="$(jq -r '.archives["llvm-mingw"].version' "$ROOT/runtime/n/inputs.lock.json")"
LM="$CACHE/work/n/toolchains/llvm-mingw-$LLVM_MINGW_VERSION-ucrt-macos-universal"
MINGW_CLANG="$LM/bin/aarch64-w64-mingw32-clang"
[ -x "$MINGW_CLANG" ] || die "no aarch64-w64-mingw32-clang at $LM (runtime/n/build.sh toolchain)"
xcrun -sdk macosx clang --version >/dev/null 2>&1 || die "no Xcode clang (xcrun)"

SRC="$ROOT/qa/n/exit-hang"
OUT="$CACHE/work/n/exit-hang"
mkdir -p "$OUT"
DYLIB="$OUT/pool-fault.dylib"
EXE="$OUT/wz-exit-thread.exe"

# Path maps keep the builder's home folder out of the test artifacts.
# shellcheck source=runtime/n/path-maps.sh
. "$ROOT/runtime/n/path-maps.sh"
read -r -a MAPS <<< "$PREFIX_MAPS"

redact() { sed -E "s#$CACHE#<cache>#g; s#$HOME#~#g; s#$(id -un)#<user>#g"; }   # cache first: it lies in the home

echo "==> build test artifacts"
if [ ! -f "$DYLIB" ] || [ "$SRC/pool-fault.m" -nt "$DYLIB" ] || [ "$0" -nt "$DYLIB" ]; then
    xcrun -sdk macosx clang -arch arm64 -mmacosx-version-min=15.0 -O2 -fno-objc-arc -fobjc-exceptions -Wall -Wextra \
        -Werror "${MAPS[@]}" -dynamiclib -framework Foundation -o "$DYLIB" "$SRC/pool-fault.m"
    codesign --force --sign - "$DYLIB"
fi
if [ ! -f "$EXE" ] || [ "$SRC/exit-thread.c" -nt "$EXE" ] || [ "$0" -nt "$EXE" ]; then
    "$MINGW_CLANG" -O2 -g0 "${MAPS[@]}" -Wall -Wextra -Werror -o "$EXE" "$SRC/exit-thread.c" -Wl,--no-insert-timestamp
fi
file "$DYLIB" "$EXE" | redact

PREFIX="$(mktemp -d "${TMPDIR:-/tmp}/wz-exit-hang.XXXXXX")/pfx"
mkdir -p "$PREFIX"
export WINEPREFIX="$PREFIX"
export WINEDEBUG="${WINEDEBUG:--all}"

cleanup() {
    WINEPREFIX="$PREFIX" "$WINESERVER" -k >/dev/null 2>&1 || true
    [ "$KEEP" = 1 ] || rm -rf "$(dirname "$PREFIX")"
}
trap cleanup EXIT

# run_limited <seconds> <cmd...>: run a command with a hard wall-clock limit (SIGKILL); returns its exit status,
# 128+N if signal N killed it, or 124 on timeout. perl keeps the alarm in a parent that never execs.
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

count() { grep -c -- "$1" "$2" || true; }   # count <pattern> <file>: matching lines (0 when none)

echo "==> boot a throwaway prefix (no injection)"
echo "    prefix: ${PREFIX/#$HOME/~}"
if ! run_limited 600 /usr/bin/env WINEDLLOVERRIDES='mscoree,mshtml=' "$WINE" wineboot -i \
        > "$OUT/wineboot.log" 2>&1; then
    tail -5 "$OUT/wineboot.log" | redact || true
    die "wineboot failed or timed out"
fi
run_limited 120 "$WINESERVER" -w >/dev/null 2>&1 || true
[ -f "$PREFIX/system.reg" ] || die "prefix did not boot"

RESULTS=()
ERRORS=0
FAILS=0
for MODE in "${MODES[@]}"; do
    echo
    echo "==> mode $MODE: run the test with the injection (timeout ${TIMEOUT}s)"
    set +e
    run_limited "$TIMEOUT" /usr/bin/env WZ_EXIT_HANG_TEST=1 WZ_EXIT_HANG_MODE="$MODE" "DYLD_INSERT_LIBRARIES=$DYLIB" \
        "$WINE" "$EXE" > "$OUT/$MODE.out" 2> "$OUT/$MODE.err"
    STATUS=$?
    set -e
    WINEPREFIX="$PREFIX" "$WINESERVER" -k >/dev/null 2>&1 || true

    # The test program is a Windows console app, so its stdout has CRLF line ends: strip CR before matching.
    tr -d '\r' < "$OUT/$MODE.out" > "$OUT/$MODE.txt"
    WRAPPED="$(count 'wz-pool-fault: wrapped' "$OUT/$MODE.err")"
    GUARD_STARTED="$(count 'wz-pool-fault: guard mode, native thread started' "$OUT/$MODE.err")"
    GUARD_PASSED="$(count 'wz-pool-fault: native thread got past the guard page' "$OUT/$MODE.err")"
    FAULTS="$(count 'wz-pool-fault: faulting' "$OUT/$MODE.err")"
    REDIRECTS="$(count 'warzag\[wz-n-0011\]: exiting-thread fault' "$OUT/$MODE.err")"
    CRASHES="$(count 'warzag\[wz-n-0011\]: .*crashing' "$OUT/$MODE.err")"
    ALLOK=0
    grep -q '^ALL OK$' "$OUT/$MODE.txt" && ALLOK=1

    echo "--- test stdout ---"
    redact < "$OUT/$MODE.txt" || true
    if [ "$MODE" = guard ]; then
        echo "--- exit status $STATUS; native thread started $GUARD_STARTED, got past the guard page $GUARD_PASSED;" \
            "engine: $CRASHES crashing ---"
    else
        echo "--- exit status $STATUS; injected threads $WRAPPED, armed faults that ran $FAULTS;" \
            "engine: $REDIRECTS redirected, $CRASHES crashing ---"
    fi
    grep -E 'warzag\[wz-n-0011\]|wine client error' "$OUT/$MODE.err" | sed -E 's/0x[0-9a-f]+/<hex>/g' | sort | uniq -c \
        | head -5 | redact || true

    NOTE=""
    [ "$REDIRECTS" = 0 ] && [ "$CRASHES" = 0 ] && \
        NOTE=" (no warzag[wz-n-0011] line: the engine did not act on the fault, as one without wz-n-0011)"
    if { [ "$MODE" = guard ] && [ "$GUARD_STARTED" = 0 ]; } || { [ "$MODE" != guard ] && [ "$WRAPPED" = 0 ]; }; then
        VERDICT=ERROR
        DETAIL="the injection did not act (no 'wz-pool-fault' start line): DYLD_INSERT_LIBRARIES did not reach the test"
    elif [ "$MODE" = guard ]; then
        if [ "$STATUS" = 0 ] && [ "$ALLOK" = 1 ] && [ "$GUARD_PASSED" -ge 1 ]; then
            VERDICT=PASS; DETAIL="the native thread got past the guard page and later faults were still handled"
        elif [ "$STATUS" = 124 ]; then
            VERDICT=FAIL; DETAIL="the test did not finish within ${TIMEOUT}s"
        elif grep -q '^FAIL guard' "$OUT/$MODE.txt"; then
            VERDICT=FAIL; DETAIL="$(grep '^FAIL guard' "$OUT/$MODE.txt" | head -1)"
        elif [ "$STATUS" -gt 128 ]; then
            VERDICT=FAIL; DETAIL="killed by signal $((STATUS - 128)) after a native thread touched a guard page"
        else
            VERDICT=FAIL; DETAIL="the test exited with status $STATUS without ALL OK"
        fi
    elif [ "$MODE" = abort ] || [ "$MODE" = trap ]; then
        if [ "$STATUS" = 124 ]; then
            VERDICT=FAIL; DETAIL="hang: still running after ${TIMEOUT}s$NOTE"
        elif grep -q '^FAIL round' "$OUT/$MODE.txt"; then
            VERDICT=FAIL; DETAIL="the stop left the process running: $(grep '^FAIL round' "$OUT/$MODE.txt" | head -1)$NOTE"
        elif [ "$ALLOK" = 1 ]; then
            VERDICT=FAIL; DETAIL="the deliberate stop was swallowed: the program printed ALL OK"
        elif [ "$STATUS" -le 128 ]; then
            VERDICT=FAIL; DETAIL="exited with status $STATUS instead of being killed by a signal$NOTE"
        elif [ "$FAULTS" -lt 1 ]; then
            VERDICT=ERROR; DETAIL="killed by signal $((STATUS - 128)) before any armed fault ran"
        elif [ "$CRASHES" -lt 1 ]; then
            VERDICT=FAIL; DETAIL="killed by signal $((STATUS - 128)) without the engine's 'crashing' line$NOTE"
        else
            VERDICT=PASS; DETAIL="the process was killed by signal $((STATUS - 128)) (the stop stayed fatal)"
        fi
    else
        if [ "$STATUS" = 0 ] && [ "$ALLOK" = 1 ] && [ "$FAULTS" -ge 3 ] && [ "$REDIRECTS" -ge 3 ]; then
            VERDICT=PASS; DETAIL="every exiting thread finished ($REDIRECTS faults redirected)"
        elif [ "$STATUS" = 0 ] && [ "$ALLOK" = 1 ] && [ "$FAULTS" -lt 3 ]; then
            VERDICT=ERROR
            DETAIL="ALL OK, but only $FAULTS armed fault(s) ran: the test no longer exercises the bug"
        elif [ "$STATUS" = 124 ]; then
            VERDICT=FAIL; DETAIL="the test did not finish within ${TIMEOUT}s (exit hang)$NOTE"
        elif grep -q '^FAIL round' "$OUT/$MODE.txt"; then
            VERDICT=FAIL; DETAIL="$(grep '^FAIL round' "$OUT/$MODE.txt" | head -1)$NOTE"
        elif [ "$ALLOK" = 1 ]; then
            VERDICT=FAIL; DETAIL="ALL OK, but the engine redirected only $REDIRECTS of $FAULTS faults"
        else
            VERDICT=FAIL; DETAIL="the test exited with status $STATUS without ALL OK$NOTE"
        fi
    fi
    echo "RESULT $MODE: $VERDICT -- $DETAIL"
    RESULTS+=("$(printf '%-8s %-5s %s' "$MODE" "$VERDICT" "$DETAIL")")
    case "$VERDICT" in ERROR) ERRORS=$((ERRORS + 1)) ;; FAIL) FAILS=$((FAILS + 1)) ;; esac
done

echo
echo "==> summary (host: $HOST)" | redact
printf '    %s\n' "${RESULTS[@]}"
if [ "$ERRORS" -gt 0 ]; then
    echo "RESULT: ERROR -- $ERRORS mode(s) could not test anything (see above)"
    exit 2
fi
if [ "$FAILS" -gt 0 ]; then
    echo "RESULT: FAIL -- $FAILS of ${#MODES[@]} mode(s) failed"
    exit 1
fi
echo "RESULT: PASS -- all ${#MODES[@]} mode(s) passed (wz-n-0011 working)"
exit 0
