#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINARY_NAME="screen-transit"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="$HOME/.config/screen-transit"
CONFIG_FILE="$CONFIG_DIR/config.yaml"
PLIST_NAME="com.screen-transit.agent"
PLIST_SOURCE="$SCRIPT_DIR/launchd/$PLIST_NAME.plist"
PLIST_DEST="$HOME/Library/LaunchAgents/$PLIST_NAME.plist"
CERT_NAME="Screen Transit Local"

VERSION=$(cat "$SCRIPT_DIR/VERSION")

if ! security find-certificate -c "$CERT_NAME" -a >/dev/null 2>&1; then
    read -s -p "Login keychain password (for code-signing setup): " KEYCHAIN_PASS
    echo
    export ST_KEYCHAIN_PASS="$KEYCHAIN_PASS"
fi

sudo -v

echo "// Auto-generated from VERSION by build.sh — do not edit manually." > "$SCRIPT_DIR/Sources/screen-transit/Version.swift"
echo "let appVersion = \"$VERSION\"" >> "$SCRIPT_DIR/Sources/screen-transit/Version.swift"

echo "==> Building $BINARY_NAME v$VERSION (release)..."
swift build -c release --package-path "$SCRIPT_DIR"

echo "==> Stopping existing agent..."
launchctl unload "$PLIST_DEST" 2>/dev/null || true

echo "==> Installing binary to $INSTALL_DIR/$BINARY_NAME..."
sudo install -m 755 \
    "$SCRIPT_DIR/.build/release/$BINARY_NAME" \
    "$INSTALL_DIR/$BINARY_NAME"

echo "==> Setting up code signing..."
"$SCRIPT_DIR/setup-signing.sh" "$INSTALL_DIR/$BINARY_NAME"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "==> Creating default config at $CONFIG_FILE..."
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" << 'YAML'
# screen-transit configuration
#
# Replace the placeholder values below with your actual device information.
#
# Discovery commands:
#   blueutil --paired                     Find Bluetooth MAC address
#   system_profiler SPBluetoothDataType   Alternative for Bluetooth MAC
#   m1ddc display list                    Find display number
#   m1ddc get input                       Find current input code
#                                         (switch input via monitor OSD first)
#
# Common DDC/CI input codes (VCP 0x60) -- verify yours with m1ddc:
#   15 = DisplayPort-1    16 = DisplayPort-2
#   17 = USB-C             4 = HDMI-1         5 = HDMI-2
#
# Reload after editing:
#   launchctl kickstart -k gui/$(id -u)/com.screen-transit.agent

# Seconds to wait before sending DDC/CI command after the trigger event.
# Increase if your monitor needs more time to wake. Default: 1.0
delay: 1.0

rules:
  # Uncomment and edit the rules below.
  #
  # - name: "Keyboard connect → DisplayPort"
  #   source: bluetooth
  #   device_id: "AA:BB:CC:DD:EE:FF"
  #   display: 1
  #   input: 15
  #   trigger: connect
  #
  # - name: "Keyboard disconnect → USB-C"
  #   source: bluetooth
  #   device_id: "AA:BB:CC:DD:EE:FF"
  #   display: 1
  #   input: 17
  #   trigger: disconnect
YAML

    CONFIG_CREATED=1
fi

echo "==> Installing launchd agent..."
mkdir -p "$HOME/Library/LaunchAgents"
cp "$PLIST_SOURCE" "$PLIST_DEST"

echo "==> Starting agent..."
launchctl load "$PLIST_DEST"

echo ""
echo "==> $BINARY_NAME deployed and running."
echo "    Logs: tail -f ~/Library/Logs/screen-transit/\$(date +%Y-%m-%d).log"
echo "    Reload after config change: launchctl kickstart -k gui/\$(id -u)/$PLIST_NAME"

if [ "${CONFIG_CREATED:-0}" = "1" ]; then
    echo ""
    echo "NOTE: A default config was created at $CONFIG_FILE"
    echo "      Edit it with your device values, then reload the agent."
fi
