#!/bin/bash
# Wrap build/PaperSift.app into a release .dmg — hdiutil only, no dependency.
# Usage: scripts/make-dmg.sh
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/bundle.sh --no-open

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" build/PaperSift.app/Contents/Info.plist)
STAGE="build/dmg-stage"
DMG="build/PaperSift-$VERSION.dmg"

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R build/PaperSift.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "PaperSift $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" > /dev/null
rm -rf "$STAGE"
echo "✅ $DMG"

# The .zip feeds the built-in OTA update (UpdateService): attach it to the
# GitHub release next to the .dmg. ditto preserves the signature.
ZIP="build/PaperSift-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent build/PaperSift.app "$ZIP"
echo "✅ $ZIP"

# The Homebrew cask pins the .zip by digest, so print it here rather than making
# every release hunt for shasum.
echo
echo "sha256 (for Casks/papersift.rb):"
shasum -a 256 "$ZIP" | cut -d' ' -f1
