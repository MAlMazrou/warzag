#!/bin/sh
# Warzag's optional one-line installer:
#
#   curl -fsSL https://<project>/install.sh | sh
#   sh install.sh [--url <Warzag.dmg URL>] [--sha256 <hex>] [--dest <dir>]
#
# Downloads the Warzag disk image, checks its SHA-256, and copies Warzag.app into /Applications (or ~/Applications
# when /Applications is not writable). Nothing else: no sudo, no other downloads, and nothing from the image is run,
# not even Warzag. Files fetched with curl carry no quarantine flag, so macOS shows no "Open Anyway" step for an app
# installed this way.
#
# A release fills in DMG_URL and DMG_SHA256 below (App/make-app.sh --dmg writes dist/install.sh). The environment
# (WARZAG_DMG_URL, WARZAG_DMG_SHA256, WARZAG_INSTALL_DIR) and the options override them.
#
# Everything runs from main(), called on the last line, so a download cut short never runs half a script.
set -eu

DMG_URL="${WARZAG_DMG_URL:-@DMG_URL@}"
DMG_SHA256="${WARZAG_DMG_SHA256:-@DMG_SHA256@}"
DEST="${WARZAG_INSTALL_DIR:-}"
TMP=""
MNT=""
ATTACHED=0
STAGED=""

fail() {
    echo "warzag-install: $*" >&2
    exit 1
}

cleanup() {
    if [ "$ATTACHED" = 1 ]; then
        hdiutil detach -quiet "$MNT" </dev/null 2>/dev/null \
            || hdiutil detach -quiet -force "$MNT" </dev/null 2>/dev/null || true
    fi
    if [ -n "$STAGED" ]; then rm -rf "$STAGED"; fi
    if [ -n "$TMP" ]; then rm -rf "$TMP"; fi
}

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --url) [ $# -ge 2 ] || fail "--url needs a value"; DMG_URL="$2"; shift 2 ;;
            --sha256) [ $# -ge 2 ] || fail "--sha256 needs a value"; DMG_SHA256="$2"; shift 2 ;;
            --dest) [ $# -ge 2 ] || fail "--dest needs a value"; DEST="$2"; shift 2 ;;
            -h|--help) echo "usage: install.sh [--url <Warzag.dmg URL>] [--sha256 <hex>] [--dest <dir>]"; exit 0 ;;
            *) fail "unknown option: $1" ;;
        esac
    done

    # The placeholder is spelled in two pieces, so filling in the DMG_URL line above cannot turn this check into one
    # that refuses the URL it was filled in with.
    case "$DMG_URL" in
        ""|*"@DMG""_URL@"*) fail "no download URL: this copy of install.sh was not filled in by a release (use --url)" ;;
        https://*|file://*) ;;
        *) fail "the download URL must be https://" ;;
    esac
    DMG_SHA256="$(printf '%s' "$DMG_SHA256" | tr 'A-F' 'a-f')"
    case "$DMG_SHA256" in
        ""|*[!0-9a-f]*) fail "no valid SHA-256 for the disk image (use --sha256)" ;;
    esac
    [ "${#DMG_SHA256}" -eq 64 ] || fail "the SHA-256 must be 64 hex digits"

    [ "$(uname -s)" = Darwin ] || fail "Warzag runs on macOS only"
    [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = 1 ] || fail "Warzag needs a Mac with Apple silicon"
    major="$(sw_vers -productVersion | cut -d. -f1)"
    [ "$major" -ge 15 ] 2>/dev/null || fail "Warzag needs macOS 15 or later"

    trap cleanup EXIT
    trap 'exit 1' INT TERM
    TMP="$(mktemp -d -t warzag-install)"
    MNT="$TMP/mount"

    echo "Downloading $DMG_URL"
    curl -fL --proto '=https,file' --proto-redir '=https' --retry 3 --progress-bar -o "$TMP/Warzag.dmg" "$DMG_URL" \
        </dev/null || fail "download failed"
    actual="$(shasum -a 256 "$TMP/Warzag.dmg" | cut -d' ' -f1)"
    [ "$actual" = "$DMG_SHA256" ] || fail "checksum mismatch (expected $DMG_SHA256, got $actual); nothing was installed"
    echo "Checksum verified"

    # stdin is this script under `curl | sh`, so no command may read it.
    mkdir "$MNT"
    hdiutil attach -quiet -nobrowse -noautoopen -readonly -mountpoint "$MNT" "$TMP/Warzag.dmg" </dev/null \
        || fail "could not open the disk image"
    ATTACHED=1
    [ -d "$MNT/Warzag.app" ] || fail "the disk image holds no Warzag.app"

    if [ -z "$DEST" ]; then
        if [ -w /Applications ]; then DEST=/Applications; else DEST="$HOME/Applications"; fi
    fi
    mkdir -p "$DEST" || fail "cannot create $DEST"
    # Absolute, so the running-copy check below matches the path a running Warzag has.
    DEST="$(CDPATH='' cd -- "$DEST" && pwd -P)" || fail "cannot open $DEST"
    [ -w "$DEST" ] || fail "cannot write to $DEST"
    if pgrep -f "$DEST/Warzag.app/Contents/MacOS/" >/dev/null 2>&1; then
        fail "Warzag is running from $DEST; quit it and run the installer again"
    fi

    # Copy next to the destination, check the copy's signature, then swap it in with two renames. If the second
    # rename fails, the previous copy is put back: an existing Warzag.app is never left renamed out of sight.
    STAGED="$DEST/.Warzag.app.installing.$$"
    ditto "$MNT/Warzag.app" "$STAGED" </dev/null || fail "copying Warzag.app into $DEST failed"
    codesign --verify --strict "$STAGED" </dev/null 2>/dev/null \
        || fail "the copied Warzag.app does not verify; nothing was installed"
    previous=""
    if [ -e "$DEST/Warzag.app" ] || [ -L "$DEST/Warzag.app" ]; then
        previous="$DEST/.Warzag.app.previous.$$"
        mv "$DEST/Warzag.app" "$previous" || fail "could not move the installed Warzag.app aside; nothing was changed"
    fi
    if ! mv "$STAGED" "$DEST/Warzag.app"; then
        if [ -n "$previous" ]; then
            mv "$previous" "$DEST/Warzag.app" \
                || fail "could not install Warzag.app; the previous copy is at $previous"
        fi
        fail "could not move the new Warzag.app into $DEST; the installed copy was left as it was"
    fi
    STAGED=""
    if [ -n "$previous" ]; then
        rm -rf "$previous" || echo "warzag-install: could not remove the previous copy at $previous" >&2
    fi

    echo "Installed $DEST/Warzag.app"
    echo "Open Warzag from $DEST (in Finder, or with Spotlight: Command-Space, Warzag) to set up Warframe."
}

main "$@"
