#!/bin/bash
# Install Warzag's Steam bridge into a Wine prefix, for development and QA (the app does the same in WineKit).
#
#   bridge/install-prefix.sh --prefix <dir> [--host <Warzag.app>]      (default host: build/n/Warzag.app)
#
# Copies the files of the host's Contents/share/warzag/bridge into C:\Program Files (x86)\Steam under Steam's own
# names and imports steam.reg with the host's Wine. lsteamclient.dll/.so are Wine builtins and stay in the host.
# Safe to run again.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="$ROOT/build/n/Warzag.app"
PREFIX=""

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix) PREFIX="$2"; shift 2 ;;
        --host) HOST="$2"; shift 2 ;;
        -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

die() { echo "error: $*" >&2; exit 1; }
[ -n "$PREFIX" ] || die "--prefix is required"
SRC="$HOST/Contents/share/warzag/bridge"
[ -f "$SRC/steam.exe" ] || die "no Steam bridge in $SRC (runtime/n/build.sh, then runtime/n/make-host.sh)"
# Wine refuses a relative WINEPREFIX.
mkdir -p "$PREFIX"
PREFIX="$(cd "$PREFIX" && pwd)"
wine() { "$ROOT/runtime/dev-wine.sh" --host "$HOST" --prefix "$PREFIX" --renderer wined3d "$@"; }

# A new prefix without the Wine Mono and Gecko install dialogs, which would wait for a click forever.
if [ ! -f "$PREFIX/system.reg" ]; then
    WINEDLLOVERRIDES='mscoree,mshtml=' wine wineboot -i >/dev/null 2>&1 || die "wineboot -i failed in $PREFIX"
fi

STEAM="$PREFIX/drive_c/Program Files (x86)/Steam"
mkdir -p "$STEAM"
install -m 644 "$SRC/steam.exe" "$STEAM/steam.exe"
install -m 644 "$SRC/steamclient64-forwarder.dll" "$STEAM/steamclient64.dll"
install -m 644 "$SRC/wz-steamprobe.exe" "$STEAM/wz-steamprobe.exe"

# Imported from inside the prefix, so it does not depend on a Z: drive mapping the Unix root.
install -m 644 "$SRC/steam.reg" "$PREFIX/drive_c/windows/temp/warzag-steam.reg"
wine reg import 'C:\windows\temp\warzag-steam.reg'
rm -f "$PREFIX/drive_c/windows/temp/warzag-steam.reg"
echo "Steam bridge installed in $PREFIX"
