#!/bin/bash
# Create, once, the project code-signing identity "Warzag Community Code Signing", or restore it from its backup.
# A stable self-signed certificate stands in for an Apple Developer ID; nothing is notarized.
#
#   tools/sign/make-cert.sh [--no-check] [--pin]
#
# Safe to run again: steps already done are skipped, and an existing certificate is never replaced.
#   login keychain        generic password "Warzag signing keychain" (service com.warzag.signing.keychain): a random
#                         password for the dedicated keychain, which also encrypts the .p12 backup
#   ~/Library/Keychains/warzag-signing.keychain-db
#                         the identity (RSA-3072, code-signing EKU, 20 years). Its key partition list lets Apple's
#                         codesign use the key without a prompt. It is not left on the keychain search list:
#                         tools/sign/sign.sh puts it there only while it signs.
#   ~/.warzag/signing/warzag-community-code-signing.p12   backup of the identity (mode 600): keep a copy offline
#   ~/.warzag/signing/warzag-community-code-signing.cer   the certificate (DER, public)
# No admin rights and no trust settings: codesign signs with an untrusted self-signed identity. Unless --no-check,
# the script proves it by signing a scratch binary and verifying the signature. It prints the certificate's SHA-256
# (what Warzag pins: RuntimeKit's signer fingerprint, tools/sign/project-certificate.sha256) and SHA-1 (what
# `codesign -s` accepts). --pin writes the SHA-256 into tools/sign/project-certificate.sha256.
# CI: set WARZAG_SIGNING_PASSWORD (and restore the .p12) instead of using the login keychain.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tools/sign/lib.sh
. "$HERE/lib.sh"

CHECK=1
PIN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --no-check) CHECK=0; shift ;;
        --pin) PIN=1; shift ;;
        -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

umask 077
mkdir -p "$WZ_SIGNING_DIR"
chmod 700 "$WZ_SIGNING_DIR"
[ "$(dirname "$WZ_SIGNING_DIR")" != "$HOME/.warzag" ] || chmod 700 "$HOME/.warzag"
WORK="$(mktemp -d -t warzag-cert)"
trap 'rm -rf "$WORK"' EXIT

# 1. The keychain password. A new one is made only when there is nothing it would have to unlock.
if PW="$(wz_keychain_password)" && [ -n "$PW" ]; then
    :
elif [ -e "$WZ_KEYCHAIN" ] || [ -e "$WZ_P12" ]; then
    wz_die "$WZ_KEYCHAIN or $WZ_P12 exists, but its password is not in the login keychain (service" \
        "$WZ_PASSWORD_SERVICE, account $WZ_PASSWORD_ACCOUNT). Put it back there, or set WARZAG_SIGNING_PASSWORD."
else
    wz_note "new random password for $WZ_KEYCHAIN, stored in the login keychain ($WZ_PASSWORD_SERVICE)"
    PW="$("$WZ_OPENSSL" rand -base64 33)"
    LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
    [ -f "$LOGIN_KEYCHAIN" ] || LOGIN_KEYCHAIN="$(security default-keychain -d user | tr -d '"' | sed 's/^[[:space:]]*//')"
    security add-generic-password -a "$WZ_PASSWORD_ACCOUNT" -s "$WZ_PASSWORD_SERVICE" -l "Warzag signing keychain" \
        -j "Unlocks $WZ_KEYCHAIN and decrypts the backup $WZ_P12 (tools/sign/make-cert.sh)" \
        -w "$PW" "$LOGIN_KEYCHAIN"
    [ "$(wz_keychain_password)" = "$PW" ] || wz_die "the password just stored in the login keychain does not read back"
fi
export WZ_P12_PASSWORD="$PW"

# 2. The certificate and its backup. Generated only if there is neither a backup nor an identity to keep.
open_keychain() {
    if [ ! -f "$WZ_KEYCHAIN" ]; then
        wz_note "create $WZ_KEYCHAIN"
        security create-keychain -p "$PW" "$WZ_KEYCHAIN"
    fi
    security unlock-keychain -p "$PW" "$WZ_KEYCHAIN" || wz_die "cannot unlock $WZ_KEYCHAIN with the stored password"
    # Lock again after an hour idle and on sleep; sign.sh unlocks it for every run.
    security set-keychain-settings -l -u -t 3600 "$WZ_KEYCHAIN"
}

open_keychain
if [ ! -f "$WZ_P12" ]; then
    if [ -n "$(wz_identity_sha1)" ]; then
        echo "warning: $WZ_KEYCHAIN holds the identity but its backup $WZ_P12 is missing; restore the backup from" \
            "your offline copy (the keychain key is not exported again, which could prompt)" >&2
    else
        wz_note "generate the self-signed certificate \"$WZ_IDENTITY\""
        cat > "$WORK/openssl.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
utf8 = yes
[ dn ]
CN = $WZ_IDENTITY
O = Warzag
[ ext ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF
        "$WZ_OPENSSL" req -x509 -new -newkey rsa:3072 -nodes -sha256 -days 7305 -config "$WORK/openssl.cnf" \
            -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
        # LibreSSL's default PKCS#12 encryption (3DES key bag) is the one `security import` reads; the random
        # 264-bit password carries the strength. Written next to its final name, then renamed into place.
        "$WZ_OPENSSL" pkcs12 -export -descert -name "$WZ_IDENTITY" -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
            -passout env:WZ_P12_PASSWORD -out "$WZ_P12.part"
        rm -f "$WORK/key.pem"
        chmod 600 "$WZ_P12.part"
        mv -n "$WZ_P12.part" "$WZ_P12"
        [ ! -e "$WZ_P12.part" ] || wz_die "$WZ_P12 appeared while generating; nothing replaced"
    fi
fi

# 3. The identity in the dedicated keychain (restored from the backup when missing).
if [ -z "$(wz_identity_sha1)" ]; then
    wz_note "import $WZ_P12 into $WZ_KEYCHAIN"
    security import "$WZ_P12" -k "$WZ_KEYCHAIN" -f pkcs12 -P "$PW" -T /usr/bin/codesign >/dev/null
fi
# Lets Apple-signed tools (codesign) use the private key without asking; re-applied every run, it is idempotent.
security set-key-partition-list -S apple-tool:,apple: -s -k "$PW" "$WZ_KEYCHAIN" >/dev/null
SHA1="$(wz_identity_sha1)"
[ -n "$SHA1" ] || wz_die "no code-signing identity \"$WZ_IDENTITY\" in $WZ_KEYCHAIN after import"

# 4. The public certificate, cross-checked against the keychain and the backup.
security find-certificate -c "$WZ_IDENTITY" -p "$WZ_KEYCHAIN" | "$WZ_OPENSSL" x509 -outform der -out "$WORK/cert.der"
[ "$(wz_sha1_of "$WORK/cert.der")" = "$SHA1" ] || wz_die "the keychain's certificate is not the identity's ($SHA1)"
if [ -f "$WZ_P12" ]; then
    "$WZ_OPENSSL" pkcs12 -in "$WZ_P12" -passin env:WZ_P12_PASSWORD -nokeys -clcerts 2>/dev/null \
        | "$WZ_OPENSSL" x509 -outform der -out "$WORK/backup.der"
    cmp -s "$WORK/cert.der" "$WORK/backup.der" || wz_die "$WZ_P12 holds a different certificate than $WZ_KEYCHAIN"
fi
if [ -f "$WZ_CER" ]; then
    cmp -s "$WORK/cert.der" "$WZ_CER" || wz_die "$WZ_CER is a different certificate than the one in $WZ_KEYCHAIN"
else
    install -m 600 "$WORK/cert.der" "$WZ_CER"
fi
SHA256="$(wz_sha256_of "$WZ_CER")"

# 5. Proof that codesign signs with it, without admin rights or trust settings.
if [ "$CHECK" = 1 ]; then
    cp /usr/bin/true "$WORK/probe"
    "$HERE/sign.sh" "$WORK/probe" >/dev/null
    authority="$(codesign -dv --verbose=2 "$WORK/probe" 2>&1 | sed -n '1,/^Authority=/s/^Authority=//p')"
    [ "$authority" = "$WZ_IDENTITY" ] || wz_die "a scratch binary signed with the identity shows authority '$authority'"
    "$HERE/verify.sh" "$WORK/probe" --fingerprint "$SHA256" >/dev/null || wz_die "the scratch binary does not verify"
    echo "check: codesign signed a scratch binary; codesign -dv shows Authority=$authority (certificate not trusted," \
        "no trust settings)"
fi

if [ "$PIN" = 1 ]; then
    printf '%s  %s\n' "$SHA256" "$WZ_IDENTITY" > "$WZ_PINNED_FINGERPRINT_FILE"
    echo "pinned: $WZ_PINNED_FINGERPRINT_FILE"
fi
pinned="$(wz_pinned_fingerprint)"
if [ -n "$pinned" ] && [ "$pinned" != "$SHA256" ]; then
    echo "warning: tools/sign/project-certificate.sha256 pins $pinned, not this certificate" >&2
fi

dates="$("$WZ_OPENSSL" x509 -inform der -in "$WZ_CER" -noout -startdate -enddate | sed 's/^[a-zA-Z]*=//' \
    | paste -sd '|' - | sed 's/|/ .. /')"
cat <<EOF
identity  $WZ_IDENTITY (self-signed; codesign needs no trust settings for it)
keychain  $WZ_KEYCHAIN
backup    $WZ_P12 (keep a copy offline; its password: security find-generic-password -s $WZ_PASSWORD_SERVICE -w)
cert      $WZ_CER
valid     $dates
SHA-256   $SHA256
SHA-1     $SHA1
EOF
