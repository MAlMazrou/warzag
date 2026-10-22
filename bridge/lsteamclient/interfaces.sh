#!/bin/bash
# Compare the Steamworks interface versions of the Mac Steam client with the ones lsteamclient wraps. Read-only;
# Steam does not need to run.
#
#   bridge/lsteamclient/interfaces.sh [--dylib <steamclient.dylib>] [--arch arm64|x86_64]
#
# Reads the version strings of the dylib slice and the interface table of lsteamclient's steamclient_generated.c
# (run runtime/n/build.sh wine-src first). Lists the versions wrapped but missing from the client (requests for
# these fail), those in the client but not wrapped, and each interface family with versions on both sides.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CACHE="${WARZAG_CACHE:-$HOME/Library/Caches/warzag-build}"
LSC="$CACHE/work/n/src/wine-$(jq -r '.archives.wine.version' "$ROOT/runtime/n/inputs.lock.json")/dlls/lsteamclient"
DYLIB="$HOME/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steamclient.dylib"
ARCH=arm64

while [ $# -gt 0 ]; do
    case "$1" in
        --dylib) DYLIB="$2"; shift 2 ;;
        --arch) ARCH="$2"; shift 2 ;;
        -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

die() { echo "error: $*" >&2; exit 1; }
[ -f "$DYLIB" ] || die "no steamclient.dylib at $DYLIB"
[ -f "$LSC/steamclient_generated.c" ] || die "no lsteamclient sources in $LSC (run runtime/n/build.sh wine-src)"

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp:?}"' EXIT

sed -n 's/^[[:space:]]*{"\([^"]*\)", &create_win.*/\1/p' "$LSC/steamclient_generated.c" | sort -u > "$tmp/wrapped"
# Versioned names (SteamUser023, STEAMAPPS_INTERFACE_VERSION008, ...) plus the few unversioned ones lsteamclient
# knows (STEAMCONTROLLER_INTERFACE_VERSION), which a plain digit pattern would miss.
strings -a -arch "$ARCH" "$DYLIB" | grep -E '^(Steam|STEAM)[A-Za-z_]*$|^(Steam|STEAM)[A-Za-z_]*[0-9]{3}[a-z]?$' \
    | sort -u > "$tmp/strings"
{ grep -E '[0-9]{3}[a-z]?$' "$tmp/strings" || true; grep -Fx -f "$tmp/wrapped" "$tmp/strings" || true; } \
    | sort -u > "$tmp/client"

manifest="$(dirname "$DYLIB")/package/steam_client_osx.manifest"
version="$(sed -n 's/^[[:space:]]*"version"[[:space:]]*"\([0-9]*\)".*/\1/p' "$manifest" 2>/dev/null | head -n 1)"
echo "Mac Steam client ${version:-(unknown version)}, $ARCH slice: $(wc -l < "$tmp/client" | tr -d ' ') interface versions"
echo "lsteamclient ($LSC): $(wc -l < "$tmp/wrapped" | tr -d ' ') interface versions"
echo
echo "Wrapped by lsteamclient but not in the client (requests for these fail):"
comm -23 "$tmp/wrapped" "$tmp/client" | sed 's/^/  /'
echo
echo "In the client but not wrapped by lsteamclient (a gap only if a game asks for one):"
comm -13 "$tmp/wrapped" "$tmp/client" | sed 's/^/  /'
echo
echo "By family (client | lsteamclient):"
family() { sed -E 's/[0-9]{3}[a-z]?$//'; }
versions() { # versions <family> <list>: the family's versions in the list, on one line
    { grep -E "^$1([0-9]{3}[a-z]?)?\$" "$2" || true; } | sed "s/^$1//; s/^\$/(unversioned)/" | tr '\n' ' '
}
for f in $(family < "$tmp/client" | sort -u); do
    c="$(versions "$f" "$tmp/client")"
    w="$(versions "$f" "$tmp/wrapped")"
    [ -n "$w" ] || continue
    printf '  %-40s %s| %s\n' "$f" "${c:-(none) }" "$w"
done
