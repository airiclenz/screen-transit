#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION=$(cat "$SCRIPT_DIR/VERSION")

echo "// Auto-generated from VERSION by build.sh — do not edit manually." > "$SCRIPT_DIR/Sources/screen-transit/Version.swift"
echo "let appVersion = \"$VERSION\"" >> "$SCRIPT_DIR/Sources/screen-transit/Version.swift"

swift build -c release --package-path "$SCRIPT_DIR"
