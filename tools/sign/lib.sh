# Shared by tools/sign/{make-cert,sign,verify}.sh and tools/release/*.sh (sourced, never executed).
#
# The project identity "Warzag Community Code Signing" is a self-signed code-signing certificate kept in its own
# keychain. The keychain's random password lives in the login keychain (or, for CI, in $WARZAG_SIGNING_PASSWORD).
# Everything below can be pointed elsewhere with the WARZAG_SIGN_* variables (tests use scratch keychains).

WZ_IDENTITY="${WARZAG_SIGN_IDENTITY:-Warzag Community Code Signing}"
WZ_KEYCHAIN="${WARZAG_SIGN_KEYCHAIN:-$HOME/Library/Keychains/warzag-signing.keychain-db}"
WZ_SIGNING_DIR="${WARZAG_SIGNING_DIR:-$HOME/.warzag/signing}"
WZ_PASSWORD_SERVICE="${WARZAG_SIGN_PASSWORD_SERVICE:-com.warzag.signing.keychain}"
WZ_PASSWORD_ACCOUNT="${WARZAG_SIGN_PASSWORD_ACCOUNT:-warzag-signing}"
WZ_BASENAME="warzag-community-code-signing"
WZ_P12="$WZ_SIGNING_DIR/$WZ_BASENAME.p12"
WZ_CER="$WZ_SIGNING_DIR/$WZ_BASENAME.cer"
# One signing run at a time per user, whichever keychain or signing directory it uses: every run edits the user's
# keychain search list (read, add or remove its keychain, write back), and two interleaved edits can take a keychain
# off the list while it signs, or leave one on it for good. Not configurable on purpose.
WZ_SIGN_LOCK="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || echo "${TMPDIR:-/tmp}/")warzag-sign.lock"
# The project certificate's SHA-256, pinned in the repository (public information, like the app's trust pins).
WZ_PINNED_FINGERPRINT_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/project-certificate.sha256"
# The release manifest key's public half, pinned in the repository too: EngineKit's RuntimeTrust pins the same key, and
# every published runtime manifest is signed with its private half (~/.warzag/keys/release-manifest.ed25519, never in
# the repository). WARZAG_RELEASE_PUBKEY_FILE points it at a scratch key (the tests do this).
WZ_RELEASE_KEY_FILE="$(dirname "$WZ_PINNED_FINGERPRINT_FILE")/release-manifest.ed25519.pub"
WZ_RELEASE_KEY_FILE="${WARZAG_RELEASE_PUBKEY_FILE:-$WZ_RELEASE_KEY_FILE}"
# LibreSSL ships with every macOS; Homebrew's OpenSSL 3+ writes PKCS#12 files `security import` cannot read.
WZ_OPENSSL=/usr/bin/openssl

wz_die() { echo "error: $*" >&2; exit 1; }
wz_note() { echo "==> $*" >&2; }

# The pinned project fingerprint, or nothing if the file is missing.
# (Pipelines here never end in an early-exiting reader such as `head` or `grep -q`: under `set -o pipefail` the
# writer's SIGPIPE would turn a match into a failure.)
wz_pinned_fingerprint() {
    [ -f "$WZ_PINNED_FINGERPRINT_FILE" ] || return 0
    awk '!done && match($0, /^[0-9a-fA-F]+/) && RLENGTH == 64 { print tolower(substr($0, 1, 64)); done = 1 }' \
        "$WZ_PINNED_FINGERPRINT_FILE"
}

# The pinned release key (the base64 of its 32 raw bytes, as `warzag-release pubkey` prints it), or nothing if the
# file is missing.
wz_release_public_key() {
    [ -f "$WZ_RELEASE_KEY_FILE" ] || return 0
    tr -d '[:space:]' < "$WZ_RELEASE_KEY_FILE"
}

# Can a player's Mac fetch from this URL? Not when its host is a reserved .invalid name (RFC 6761: it never resolves),
# such as the placeholders' releases.warzag.invalid. A manifest for any other URL must be signed with the release key
# the app pins (tools/release/mkpack.sh, tools/release/mkappupdate.sh).
wz_reaches_players() {
    local host="${1#*://}"
    host="${host%%[/?#]*}"
    host="${host##*@}"
    host="${host%%:*}"
    case "$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')" in
        invalid|*.invalid) return 1 ;;
        *) return 0 ;;
    esac
}

# The keychain password: $WARZAG_SIGNING_PASSWORD, else the login keychain item. Fails if neither exists.
wz_keychain_password() {
    if [ -n "${WARZAG_SIGNING_PASSWORD:-}" ]; then
        printf '%s' "$WARZAG_SIGNING_PASSWORD"
        return 0
    fi
    security find-generic-password -s "$WZ_PASSWORD_SERVICE" -a "$WZ_PASSWORD_ACCOUNT" -w 2>/dev/null
}

# Lowercase hex SHA-256 / uppercase hex SHA-1 of a DER certificate file.
wz_sha256_of() { shasum -a 256 "$1" | awk '{print tolower($1)}'; }
wz_sha1_of() { shasum -a 1 "$1" | awk '{print toupper($1)}'; }

# The SHA-1 hash codesign should sign with: the identity named $WZ_IDENTITY in $WZ_KEYCHAIN. A self-signed
# certificate is never "valid" (CSSMERR_TP_NOT_TRUSTED), so this reads the full list, not `-v`.
wz_identity_sha1() {
    security find-identity -p codesigning "$WZ_KEYCHAIN" 2>/dev/null \
        | awk -v name="\"$WZ_IDENTITY\"" '!found && index($0, name) && $2 ~ /^[0-9A-F]{40}$/ {print $2; found = 1}'
}

# A path with its directory resolved (security reports /private/var/... for a keychain created as /var/...).
wz_canonical() {
    local dir
    if dir="$(cd "$(dirname "$1")" 2>/dev/null && pwd -P)"; then echo "$dir/$(basename "$1")"; else echo "$1"; fi
}

# The user's keychain search list, one path per line.
wz_search_list() {
    security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//'
}

# Is the signing keychain on the user's search list?
wz_keychain_attached() {
    local line target
    target="$(wz_canonical "$WZ_KEYCHAIN")"
    while IFS= read -r line; do
        [ -n "$line" ] && [ "$(wz_canonical "$line")" = "$target" ] && return 0
    done < <(wz_search_list)
    return 1
}

# codesign only finds identities in keychains on the user's search list (`codesign --keychain` alone reports "no
# identity found"), so the signing keychain is added for the duration of a signing run and removed afterwards.
# Keeping it there permanently would make other apps ask to unlock it whenever they enumerate identities.
wz_attach_keychain() {
    local current=() line
    wz_keychain_attached && return 0
    while IFS= read -r line; do
        [ -n "$line" ] && current+=("$line")
    done < <(wz_search_list)
    security list-keychains -d user -s ${current[@]+"${current[@]}"} "$(wz_canonical "$WZ_KEYCHAIN")"
}

wz_detach_keychain() {
    local keep=() line target
    target="$(wz_canonical "$WZ_KEYCHAIN")"
    while IFS= read -r line; do
        [ -n "$line" ] && [ "$(wz_canonical "$line")" != "$target" ] && keep+=("$line")
    done < <(wz_search_list)
    security list-keychains -d user -s ${keep[@]+"${keep[@]}"}
}

# Is this regular file a Mach-O (thin or universal)? Reads the magic number, so it is cheap on thousands of files.
wz_is_macho() {
    local magic
    magic="$(head -c 4 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')"
    case "$magic" in
        cffaedfe|cefaedfe|feedfacf|feedface) return 0 ;;
        # Universal binaries share CAFEBABE with Java class files; let file(1) tell them apart.
        cafebabe|bebafeca) case "$(file -b "$1")" in Mach-O*) return 0 ;; *) return 1 ;; esac ;;
        *) return 1 ;;
    esac
}

# A bundle's main executable (CFBundleExecutable), or nothing for a plain file.
wz_main_executable() {
    local plist="$1/Contents/Info.plist" name
    [ -f "$plist" ] || return 0
    name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist" 2>/dev/null)" || return 0
    [ -n "$name" ] && echo "$1/Contents/MacOS/$name"
}
