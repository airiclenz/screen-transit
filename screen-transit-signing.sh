#!/bin/bash
set -euo pipefail

CERT_NAME="Screen Transit Local"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
BINARY="${1:-}"

has_valid_identity() {
    # Note: deliberately no -v. Self-signed certs without an explicit trust
    # setting are filtered out by -v ("Valid identities only"), but codesign
    # accepts them fine. Skipping -v lets us avoid the trust-settings GUI
    # popup that `security add-trusted-cert` triggers.
    security find-identity -p codesigning 2>/dev/null \
        | grep -q "\"$CERT_NAME\""
}

sign_binary() {
    local binary="$1"
    if codesign -s "$CERT_NAME" -f "$binary" 2>&1; then
        echo "==> Signed: $binary"
    else
        echo "ERROR: codesign failed for $binary."
        exit 1
    fi
}

remove_duplicate_certs() {
    local count
    count=$(security find-certificate -c "$CERT_NAME" -a 2>/dev/null \
        | grep -c "labl" || true)
    if [ "$count" -gt 1 ]; then
        echo "==> Found $count duplicate certificates, cleaning up..."
        while [ "$count" -gt 1 ]; do
            security delete-certificate -c "$CERT_NAME" 2>/dev/null || break
            count=$(security find-certificate -c "$CERT_NAME" -a 2>/dev/null \
                | grep -c "labl" || true)
        done
    fi
}

if has_valid_identity; then
    remove_duplicate_certs
    echo "Code-signing identity \"$CERT_NAME\" already present."
    if [ -n "$BINARY" ]; then
        sign_binary "$BINARY"
    fi
    exit 0
fi

# No usable identity — clean up any orphan cert (cert without private key)
# before creating a fresh one, otherwise the import will create a duplicate.
if security find-certificate -c "$CERT_NAME" >/dev/null 2>&1; then
    echo "==> Removing orphan certificate (no codesigning identity)..."
    security delete-identity -c "$CERT_NAME" 2>/dev/null || true
    security delete-certificate -c "$CERT_NAME" 2>/dev/null || true
fi

KEYCHAIN_PASS="${ST_KEYCHAIN_PASS:-}"
if [ -z "$KEYCHAIN_PASS" ]; then
    # Read from /dev/tty so `-s` (no-echo) works even when stdin was
    # inherited from a parent process (e.g. `screen-transit --init`).
    if [ -r /dev/tty ]; then
        read -s -p "Login keychain password (for code-signing setup): " \
            KEYCHAIN_PASS < /dev/tty
        echo
    else
        echo "ERROR: No terminal available for password prompt."
        echo "       Run manually: screen-transit-signing.sh"
        exit 1
    fi
fi

TMPDIR_CERT="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_CERT"' EXIT

echo "==> Creating self-signed code-signing certificate..."

/usr/bin/openssl req -x509 -newkey rsa:2048 \
    -keyout "$TMPDIR_CERT/key.pem" \
    -out "$TMPDIR_CERT/cert.pem" \
    -days 3650 -nodes \
    -subj "/CN=$CERT_NAME" \
    -addext "keyUsage=digitalSignature" \
    -addext "extendedKeyUsage=codeSigning" \
    2>/dev/null

/usr/bin/openssl pkcs12 -export \
    -out "$TMPDIR_CERT/cert.p12" \
    -inkey "$TMPDIR_CERT/key.pem" \
    -in "$TMPDIR_CERT/cert.pem" \
    -passout pass:screen-transit-tmp \
    2>/dev/null

security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN" 2>/dev/null || true

# Two separate access mechanisms control whether codesign can use the key:
#   1. The ACL (`-A` = "any app, no warning") — short-circuits the key ACL.
#   2. The partition list (set-key-partition-list) — required since macOS
#      Sierra for any app to use the key without an interactive prompt.
# Both are set so that fresh installs work, AND so that users with stale
# keychain state (orphan keys from prior runs) don't hit a runtime
# "codesign wants to access key" popup.
# `set-key-partition-list -k "$KEYCHAIN_PASS"` is non-interactive because
# the password is supplied; only `add-trusted-cert` would trigger a GUI
# dialog, which we deliberately skip (trust isn't needed for our use case
# — TCC keys permissions to the signing identity hash regardless of trust).
security import "$TMPDIR_CERT/cert.p12" \
    -k "$KEYCHAIN" \
    -P screen-transit-tmp \
    -A

security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s -k "$KEYCHAIN_PASS" \
    -c "$CERT_NAME" \
    "$KEYCHAIN" >/dev/null 2>&1 || true

if ! security find-certificate -c "$CERT_NAME" >/dev/null 2>&1; then
    echo "ERROR: Certificate was imported but not found."
    echo "       Open Keychain Access, find \"$CERT_NAME\", and set Trust → Code Signing → Always Trust."
    exit 1
fi

echo "==> Certificate \"$CERT_NAME\" created and ready for code signing."

if [ -n "$BINARY" ]; then
    sign_binary "$BINARY"
fi
