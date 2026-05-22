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
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
if security find-certificate -c "$CERT_NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    read -p "==> Remove code-signing certificate \"$CERT_NAME\"? [y/N] " answer
    if [[ "${answer:-N}" =~ ^[Yy]$ ]]; then
        security delete-identity -c "$CERT_NAME" 2>/dev/null || true
        security delete-certificate -c "$CERT_NAME" 2>/dev/null || true
        echo "    Certificate removed."
    else
        echo "    Certificate kept."
    fi
fi

echo ""
echo "==> $BINARY_NAME uninstalled."
