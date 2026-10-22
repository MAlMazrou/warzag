#!/bin/bash
# Verify a signed bundle (or one file) strictly, Mach-O by Mach-O.
#
#   tools/sign/verify.sh <bundle|file> [--fingerprint <sha256>|adhoc|any] [--quiet]
#
# Checks:
#   - `codesign --verify --strict` on every Mach-O file and then on the bundle: each signature is intact, every
#     resource is sealed and unchanged, nothing was added or removed;
#   - no hardened runtime anywhere (Warzag ships without it);
#   - the leaf certificate of every signature has the expected SHA-256, the value RuntimeKit pins for runtime packs.
#     Default: the project certificate pinned in tools/sign/project-certificate.sha256. `adhoc` expects ad-hoc
#     signatures everywhere; `any` accepts any one signer, as long as it is the same everywhere.
# Gatekeeper is not consulted: Warzag is not notarized, so `spctl` rejects it by design.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tools/sign/lib.sh
. "$HERE/lib.sh"

TARGET=""
EXPECTED=""
QUIET=0
while [ $# -gt 0 ]; do
    case "$1" in
        --fingerprint) [ $# -ge 2 ] || wz_die "--fingerprint needs a value"; EXPECTED="$2"; shift 2 ;;
        --quiet) QUIET=1; shift ;;
        -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
        -*) echo "unknown option: $1" >&2; exit 2 ;;
        *) [ -z "$TARGET" ] || wz_die "only one bundle or file at a time"; TARGET="$1"; shift ;;
    esac
done
[ -n "$TARGET" ] || { echo "usage: $0 <bundle|file> [--fingerprint <sha256>|adhoc|any]" >&2; exit 2; }
[ -e "$TARGET" ] || wz_die "$TARGET does not exist"
if [ -z "$EXPECTED" ]; then
    EXPECTED="$(wz_pinned_fingerprint)"
    [ -n "$EXPECTED" ] || wz_die "no --fingerprint given and nothing pinned in $WZ_PINNED_FINGERPRINT_FILE"
fi
case "$EXPECTED" in
    adhoc|any) ;;
    *) EXPECTED="$(tr 'A-F' 'a-f' <<<"$EXPECTED")"
       [[ "$EXPECTED" =~ ^[0-9a-f]{64}$ ]] || wz_die "--fingerprint must be a SHA-256 (64 hex digits), adhoc or any" ;;
esac

WORK="$(mktemp -d -t warzag-verify)"
trap 'rm -rf "$WORK"' EXIT

items=()
if [ -d "$TARGET" ]; then
    while IFS= read -r -d '' file; do
        if wz_is_macho "$file"; then items+=("$file"); fi
    done < <(find "$TARGET" -type f -print0)
fi
items+=("$TARGET")

failures=0
fail() { echo "FAIL  ${1#"$TARGET"/}: $2" >&2; failures=$((failures + 1)); }
signer=""
for item in "${items[@]}"; do
    if ! out="$(codesign --verify --strict "$item" 2>&1)"; then
        fail "$item" "$(tr '\n' ' ' <<<"$out")"
        continue
    fi
    details="$(codesign -d --verbose=2 "$item" 2>&1)"
    code_directory="$(sed -n 's/^CodeDirectory .*flags=//p' <<<"$details")"
    case "$code_directory" in
        *runtime*) fail "$item" "signed with the hardened runtime" ;;
    esac
    if [[ $'\n'"$details"$'\n' == *$'\nSignature=adhoc\n'* ]]; then
        fingerprint=adhoc
    else
        rm -f "$WORK"/cert*
        codesign -d --extract-certificates="$WORK/cert" "$item" >/dev/null 2>&1 || true
        if [ ! -s "$WORK/cert0" ]; then
            fail "$item" "no certificate in its signature"
            continue
        fi
        fingerprint="$(wz_sha256_of "$WORK/cert0")"
    fi
    if [ "$EXPECTED" = any ]; then
        [ -n "$signer" ] || signer="$fingerprint"
        [ "$fingerprint" = "$signer" ] || fail "$item" "signed by $fingerprint, the rest by $signer"
    elif [ "$fingerprint" != "$EXPECTED" ]; then
        fail "$item" "signed by $fingerprint, expected $EXPECTED"
    else
        signer="$fingerprint"
    fi
done

count=$((${#items[@]} - 1))
if [ $failures -gt 0 ]; then
    echo "verify: $failures problem(s) in $TARGET" >&2
    exit 1
fi
if [ "$QUIET" = 0 ]; then
    what="$TARGET"
    [ ! -d "$TARGET" ] || what="$TARGET ($count Mach-O files and the bundle)"
    echo "verified $what: strict signatures, no hardened runtime, signer $signer"
fi
