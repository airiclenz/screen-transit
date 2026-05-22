#!/bin/bash
set -euo pipefail

CERT_NAME="Screen Transit Local"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
TMPDIR_CERT="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_CERT"' EXIT

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "Code-signing certificate \"$CERT_NAME\" already exists."
    exit 0
fi

KEYCHAIN_PASS="${ST_KEYCHAIN_PASS:-}"
if [ -z "$KEYCHAIN_PASS" ]; then
    read -s -p "Login keychain password (for code-signing setup): " KEYCHAIN_PASS
    echo
fi

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

security import "$TMPDIR_CERT/cert.p12" \
    -k "$KEYCHAIN" \
    -P screen-transit-tmp \
    -T /usr/bin/codesign \
    -T /usr/bin/security

security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s -k "$KEYCHAIN_PASS" \
    -c "$CERT_NAME" \
    "$KEYCHAIN" >/dev/null 2>&1

sudo security add-trusted-cert -d -p codeSign \
    -k /Library/Keychains/System.keychain \
    "$TMPDIR_CERT/cert.pem"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "==> Certificate \"$CERT_NAME\" created and trusted for code signing."
else
    echo "ERROR: Certificate was imported but not recognized for code signing."
    echo "       Open Keychain Access, find \"$CERT_NAME\", and set Trust → Code Signing → Always Trust."
    exit 1
fi
