#!/bin/bash
# Check Warzag's PE test programs: PE32+ x86-64 console executables that import only Windows system DLLs.
# A stray libgcc_s_seh-1.dll or libwinpthread-1.dll import would stop a program from starting in a clean prefix.
#
#   qa/pe/check-pe.sh <exe>...        (make -C qa/pe check runs it on everything it builds)
set -euo pipefail

OBJDUMP="${OBJDUMP:-x86_64-w64-mingw32-objdump}"
# Kernel, window, Direct3D and WinHTTP DLLs, plus the UCRT API sets the C runtime is reached through.
ALLOWED='^(kernel32|user32|d3d11|dxgi|winhttp|api-ms-win-crt-[a-z0-9-]+)\.dll$'

[ $# -gt 0 ] || { echo "usage: $0 <exe>..." >&2; exit 2; }
status=0
for exe in "$@"; do
    headers="$("$OBJDUMP" -p "$exe")"
    imports="$(awk '/DLL Name:/ {print $3}' <<<"$headers")"
    unexpected="$(grep -Eiv "$ALLOWED" <<<"$imports" || true)"
    problems=""
    grep -q 'file format pei-x86-64' <<<"$headers" || problems+=" not-x86-64"
    grep -Eq '^Magic[[:space:]]+020b' <<<"$headers" || problems+=" not-PE32+"
    grep -Eq '^Subsystem[[:space:]]+00000003' <<<"$headers" || problems+=" not-console"
    [ -z "$unexpected" ] || problems+=" imports:$(echo $unexpected | tr ' ' ',')"
    if [ -z "$problems" ]; then
        echo "ok    $(basename "$exe"): PE32+ x86-64 console; imports $(echo $imports)"
    else
        echo "FAIL  $(basename "$exe"):$problems"
        status=1
    fi
done
exit $status
