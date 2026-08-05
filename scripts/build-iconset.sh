#!/bin/bash
# Derives the .icns from the code-drawn master: scripts/build-iconset.sh
set -euo pipefail
cd "$(dirname "$0")/.."

swift scripts/make-icon.swift

ICONSET="build/icon/PaperSift.iconset"
MASTER="build/icon/icon_1024.png"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$MASTER" --out "$ICONSET/icon_${size}x${size}.png" > /dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$MASTER" --out "$ICONSET/icon_${size}x${size}@2x.png" > /dev/null
done

iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
echo "✅ Resources/AppIcon.icns"
