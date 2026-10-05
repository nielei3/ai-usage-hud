#!/bin/bash
# Assemble UsageHUD.app from the SwiftPM executable (unsigned, LSUIElement).
set -euo pipefail
cd "$(dirname "$0")/.."
APP="build/UsageHUD.app"
BIN=$(swift build -c release --show-bin-path)
swift build -c release
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/UsageHUD" "$APP/Contents/MacOS/UsageHUD"
cp scripts/Info.plist "$APP/Contents/Info.plist"
touch "$APP"
echo "$APP"
