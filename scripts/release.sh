#!/usr/bin/env bash
# Build a release .dmg of Parola.
# Stops short of notarization, which needs the developer's Apple credentials.
# See RELEASING.md for the full release ritual.

set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  VERSION=$(grep -E 'MARKETING_VERSION:' ParolaApp/project.yml | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
fi

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "✘ xcodegen not found. Install with: brew install xcodegen"; exit 1
fi
if ! command -v create-dmg >/dev/null 2>&1; then
  echo "ℹ create-dmg not found. Falling back to hdiutil. For a nicer DMG: brew install create-dmg"
fi

DIST="dist"
ARCHIVE="$DIST/Parola-$VERSION.xcarchive"
EXPORT="$DIST/Parola-$VERSION"
DMG="$DIST/Parola-$VERSION.dmg"

mkdir -p "$DIST"
rm -rf "$ARCHIVE" "$EXPORT" "$DMG"

echo "▶ Regenerating Xcode project…"
(cd ParolaApp && xcodegen generate >/dev/null)

echo "▶ Archiving…"
xcodebuild \
  -project ParolaApp/ParolaApp.xcodeproj \
  -scheme ParolaApp \
  -configuration Release \
  -archivePath "$ARCHIVE" \
  archive | xcpretty || true

if [ ! -d "$ARCHIVE" ]; then
  echo "✘ Archive failed."; exit 1
fi

cat > "$DIST/exportOptions.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>signingStyle</key>
    <string>manual</string>
</dict>
</plist>
PLIST

echo "▶ Exporting .app…"
xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT" \
  -exportOptionsPlist "$DIST/exportOptions.plist" || {
    echo "✘ Export failed. This usually means there's no Developer ID signing identity in your Keychain."
    echo "  Run: security find-identity -v -p codesigning"
    echo "  Then update ParolaApp/project.yml DEVELOPMENT_TEAM and CODE_SIGN_IDENTITY."
    exit 1
  }

APP_PATH="$EXPORT/Parola.app"
echo "▶ Built $APP_PATH"

if command -v create-dmg >/dev/null 2>&1; then
  create-dmg --volname "Parola $VERSION" --window-size 540 380 --icon-size 96 --app-drop-link 380 200 "$DMG" "$APP_PATH"
else
  hdiutil create -volname "Parola $VERSION" -srcfolder "$APP_PATH" -ov -format UDZO "$DMG"
fi

echo
echo "✓ Built $DMG"
echo
echo "Next steps (manual):"
echo "  1. Notarize:    xcrun notarytool submit \"$DMG\" --apple-id <you@example.com> --team-id <TEAM> --password <app-specific> --wait"
echo "  2. Staple:      xcrun stapler staple \"$DMG\""
echo "  3. Sign Sparkle update with your private EdDSA key:"
echo "       ./scripts/sign-update.sh \"$DMG\""
echo "  4. Upload \$DMG and append the printed <item> to your appcast.xml."
