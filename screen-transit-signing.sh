#!/bin/bash
set -euo pipefail

CERT_NAME="Screen Transit Local"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
BINARY="${1:-}"

# ----- helpers ------------------------------------------------------------

# Count codesigning identities matching CERT_NAME.
# Note: no -v on find-identity — self-signed certs without an explicit
# trust setting are filtered out by -v but codesign accepts them fine.
count_identities() {
    security find-identity -p codesigning 2>/dev/null \
        | grep -c "\"$CERT_NAME\"" || true
}

# SHA-1 of the first matching identity, used to disambiguate codesign when
# duplicates exist (`codesign -s "$NAME"` fails with "ambiguous" otherwise).
first_identity_hash() {
    security find-identity -p codesigning 2>/dev/null \
        | grep "\"$CERT_NAME\"" | head -1 | awk '{print $2}'
}

# Hash-based purge — `delete-certificate -c <name>` fails with "ambiguous"
# when multiple certs share the common name, so loop by SHA-1 instead.
purge_all_certs() {
    while hash=$(security find-certificate -c "$CERT_NAME" -Z 2>/dev/null \
            | awk '/SHA-1/{print $NF; exit}'); [ -n "$hash" ]; do
        security delete-certificate -Z "$hash" 2>/dev/null || break
    done
    # Catch any private keys whose identity link survived the cert deletion.
    while security delete-identity -c "$CERT_NAME" >/dev/null 2>&1; do :; done
}

sign_binary() {
    local binary="$1"
    local hash
    hash=$(first_identity_hash)
    if [ -z "$hash" ]; then
        echo "ERROR: No codesigning identity found for $CERT_NAME"
        exit 1
    fi
    if codesign -s "$hash" -f "$binary" 2>&1; then
        echo "==> Signed: $binary"
    else
        echo "ERROR: codesign failed for $binary."
        exit 1
    fi
}

# ----- main flow ----------------------------------------------------------

# Reset mode (ST_RESET=1) nukes existing certs so a stuck install — e.g.
# a cert created without a partition list that triggers a runtime
# "codesign wants to access key" popup — can recover cleanly.
if [ "${ST_RESET:-0}" = "1" ]; then
    echo "==> Reset requested: purging all '$CERT_NAME' certs and identities..."
    purge_all_certs
fi

identity_count=$(count_identities)

if [ "$identity_count" = "1" ]; then
    echo "Code-signing identity \"$CERT_NAME\" already present."
    if [ -n "$BINARY" ]; then
        sign_binary "$BINARY"
    fi
    exit 0
fi

if [ "$identity_count" -gt 1 ]; then
    echo "==> Found $identity_count duplicate '$CERT_NAME' identities;" \
         "recreating cleanly..."
fi

# Either no identity, or duplicates — full purge before fresh creation.
purge_all_certs

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
    exit 1
fi

echo "==> Certificate \"$CERT_NAME\" created and ready for code signing."

if [ -n "$BINARY" ]; then
    sign_binary "$BINARY"
fi
