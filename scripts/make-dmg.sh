#!/usr/bin/env bash
# Build HubPlus.app (Release) and package it into a distributable .dmg.
#
# Usage: scripts/make-dmg.sh
# Output: dist/HubPlus-<version>.dmg (version read from project.yml)
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

VERSION=$(grep -m1 'MARKETING_VERSION' project.yml | sed -E 's/.*MARKETING_VERSION: *"?([0-9A-Za-z.+-]+)"?.*/\1/')
if [[ -z "$VERSION" ]]; then
  echo "error: could not read MARKETING_VERSION from project.yml" >&2
  exit 1
fi

DERIVED_DATA=".build/dmg-derived-data"
STAGING=".build/dmg-staging"
DIST_DIR="dist"
DMG_PATH="${DIST_DIR}/HubPlus-${VERSION}.dmg"

echo "==> Generating Xcode project"
xcodegen generate

echo "==> Building HubPlus.app (Release)"
rm -rf "$DERIVED_DATA"
xcodebuild -project HubPlus.xcodeproj -scheme HubPlus -configuration Release \
  -derivedDataPath "$DERIVED_DATA" build

APP_PATH="${DERIVED_DATA}/Build/Products/Release/HubPlus.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "error: build did not produce $APP_PATH" >&2
  exit 1
fi

echo "==> Staging DMG contents"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP_PATH" "$STAGING/HubPlus.app"
ln -s /Applications "$STAGING/Applications"

echo "==> Creating $DMG_PATH"
mkdir -p "$DIST_DIR"
rm -f "$DMG_PATH"
hdiutil create -volname "Hub+" -srcfolder "$STAGING" -ov -format UDZO "$DMG_PATH"

# --- Notarization (optional, requires an Apple Developer ID and stored credentials) ---
# xcrun notarytool submit "$DMG_PATH" --keychain-profile "HubPlus-notary" --wait
# xcrun stapler staple "$DMG_PATH"

echo "==> Done: $DMG_PATH"
echo "Note: this build is ad-hoc signed, not notarized. On another machine, Gatekeeper"
echo "will quarantine it; before first launch run:"
echo "  xattr -dr com.apple.quarantine /Applications/HubPlus.app"
