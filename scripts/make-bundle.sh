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
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Sources/UsageHUD/Panel/Assets/claude-icon.png "$APP/Contents/Resources/claude-icon.png"
cp Sources/UsageHUD/Panel/Assets/codex-icon.png "$APP/Contents/Resources/codex-icon.png"
touch "$APP"
echo "$APP"
