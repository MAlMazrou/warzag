#!/bin/bash
# Run a Windows program with a locally built Warzag runtime, for development (the app builds the same environment in
# WineKit).
#
#   runtime/dev-wine.sh [--host <Warzag.app>] [--prefix <dir>] [--renderer dxmt|dxmt-nvext|wined3d]
#                       [--steam] [--] <program> [args...]
#
# Defaults: host build/n/Warzag.app, prefix $WARZAG_CACHE/prefixes/dev, renderer dxmt. --steam adds the environment
# Steam gives Warframe (app 230410).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="${WARZAG_CACHE:-$HOME/Library/Caches/warzag-build}"
HOST="$ROOT/build/n/Warzag.app"
PREFIX="$CACHE/prefixes/dev"
RENDERER="dxmt"
STEAM=0

while [ $# -gt 0 ]; do
    case "$1" in
        --host) HOST="$2"; shift 2 ;;
        --prefix) PREFIX="$2"; shift 2 ;;
        --renderer) RENDERER="$2"; shift 2 ;;
        --steam) STEAM=1; shift ;;
        --) shift; break ;;
        -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
        *) break ;;
    esac
done
[ $# -gt 0 ] || { echo "usage: $0 [options] <program> [args...]" >&2; exit 2; }

[ -x "$HOST/Contents/MacOS/wine" ] || { echo "error: no runtime at $HOST (run runtime/n/make-host.sh)" >&2; exit 1; }
mkdir -p "$PREFIX"
# Absolute paths only: Wine cannot turn a relative WINEDLLPATH_PREPEND entry into an NT path, so a relative --host
# makes every overlay DLL fail to load (c000003b) and d3d11/dxgi silently fall back to Wine's own.
HOST="$(cd "$HOST" && pwd -P)"
PREFIX="$(cd "$PREFIX" && pwd -P)"
C="$HOST/Contents"

export WINEPREFIX="$PREFIX"
export WINEDEBUG="${WINEDEBUG:--all}"
export SteamDeck=0
unset WINEDLLPATH_PREPEND DXMT_ENABLE_NVEXT

case "$RENDERER" in
    dxmt) export WINEDLLPATH_PREPEND="$C/renderers/dxmt" ;;
    dxmt-nvext) export WINEDLLPATH_PREPEND="$C/renderers/dxmt" DXMT_ENABLE_NVEXT=1 ;;
    wined3d) ;;
    *) echo "error: unknown renderer $RENDERER" >&2; exit 2 ;;
esac

if [ "$STEAM" = 1 ]; then
    export SteamAppId=230410 SteamGameId=230410 SteamOverlayGameId=230410 STEAM_COMPAT_APP_ID=230410
    export STEAM_COMPAT_CLIENT_INSTALL_PATH="$HOME/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS"
fi

exec "$C/MacOS/wine" "$@"
