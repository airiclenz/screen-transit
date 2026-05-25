#!/bin/bash
set -euo pipefail

BINARY_NAME="screen-transit"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="$HOME/.config/screen-transit"
PLIST_NAME="com.screen-transit.agent"
PLIST_DEST="$HOME/Library/LaunchAgents/$PLIST_NAME.plist"
LOG_DIR="$HOME/Library/Logs/screen-transit"

echo "==> Stopping agent..."
launchctl unload "$PLIST_DEST" 2>/dev/null || true

echo "==> Removing launchd plist..."
rm -f "$PLIST_DEST"

echo "==> Removing binary..."
sudo rm -f "$INSTALL_DIR/$BINARY_NAME"

read -p "==> Remove config at $CONFIG_DIR? [y/N] " answer
if [[ "${answer:-N}" =~ ^[Yy]$ ]]; then
    rm -rf "$CONFIG_DIR"
    echo "    Config removed."
else
    echo "    Config kept."
fi

read -p "==> Remove logs at $LOG_DIR? [y/N] " answer
if [[ "${answer:-N}" =~ ^[Yy]$ ]]; then
    rm -rf "$LOG_DIR"
    echo "    Logs removed."
else
    echo "    Logs kept."
fi

CERT_NAME="Screen Transit Local"
if security find-certificate -c "$CERT_NAME" >/dev/null 2>&1; then
    read -p "==> Remove code-signing certificate \"$CERT_NAME\"? [y/N] " answer
    if [[ "${answer:-N}" =~ ^[Yy]$ ]]; then
        # Delete every matching cert by SHA-1 hash. Looping by hash avoids
        # the ambiguity that breaks `delete-certificate -c <name>` when
        # multiple certs share the same common name.
        while hash=$(security find-certificate -c "$CERT_NAME" -Z 2>/dev/null \
                | awk '/SHA-1/{print $NF; exit}'); [ -n "$hash" ]; do
            security delete-certificate -Z "$hash" 2>/dev/null || break
        done
        # Catch any private keys whose identity link survived above.
        while security delete-identity -c "$CERT_NAME" >/dev/null 2>&1; do :; done
        echo "    Certificate(s) removed."
    else
        echo "    Certificate kept."
    fi
fi

echo ""
echo "==> $BINARY_NAME uninstalled."
