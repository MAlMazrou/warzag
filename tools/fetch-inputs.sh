#!/bin/bash
# Download and verify the pinned archives of runtime/inputs.lock.json into $WARZAG_CACHE/downloads/<name>/<file>.
#
#   tools/fetch-inputs.sh [name ...]      (default: every archive)
set -euo pipefail

case "${1:-}" in
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCK="$ROOT/runtime/inputs.lock.json"
CACHE="${WARZAG_CACHE:-$HOME/Library/Caches/warzag-build}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "error: '$1' is required" >&2; exit 1; }; }
need jq
need curl
need shasum

for n in "$@"; do
    jq -e --arg n "$n" '.archives | has($n)' "$LOCK" >/dev/null || { echo "unknown input: $n" >&2; exit 2; }
done

SELECTED=("$@")
NSEL=$#
want() {
    [ "$NSEL" -eq 0 ] && return 0
    local n
    for n in "${SELECTED[@]}"; do [ "$n" = "$1" ] && return 0; done
    return 1
}

fetch_archive() {
    local name="$1" url sha size file dir
    url=$(jq -r --arg n "$name" '.archives[$n].url' "$LOCK")
    sha=$(jq -r --arg n "$name" '.archives[$n].sha256' "$LOCK")
    size=$(jq -r --arg n "$name" '.archives[$n].size // empty' "$LOCK")
    file="${url##*/}"
    dir="$CACHE/downloads/$name"
    mkdir -p "$dir"

    if [ -f "$dir/$file" ] && echo "$sha  $dir/$file" | shasum -a 256 -c --status; then
        echo "ok      $name ($file, cached)"
        return
    fi
    echo "fetch   $name <- $url"
    curl -fL --retry 5 --retry-delay 3 -C - -o "$dir/$file.part" "$url"
    if [ -n "$size" ]; then
        local got
        got=$(stat -f %z "$dir/$file.part")
        [ "$got" = "$size" ] || { echo "error: $name size $got != $size" >&2; exit 1; }
    fi
    echo "$sha  $dir/$file.part" | shasum -a 256 -c --status \
        || { echo "error: $name sha256 mismatch" >&2; rm -f "$dir/$file.part"; exit 1; }
    mv "$dir/$file.part" "$dir/$file"
    echo "ok      $name ($file)"
}

for name in $(jq -r '.archives | keys[]' "$LOCK"); do
    want "$name" && fetch_archive "$name"
done
