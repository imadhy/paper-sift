#!/bin/bash
# Assemble PaperSift.app from the SwiftPM build — no Xcode required.
# Usage: scripts/bundle.sh [--no-open]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=release
swift build -c "$CONFIG"

APP="build/PaperSift.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/PaperSift" "$APP/Contents/MacOS/PaperSift"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ -f Resources/AppIcon.icns ]]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# Ad-hoc signature: enough for local use, no Apple Developer account needed.
codesign --force --sign - "$APP"

echo "✅ Bundle ready: $APP"
if [[ "${1:-}" != "--no-open" ]]; then
  open "$APP"
fi
