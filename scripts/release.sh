#!/usr/bin/env bash
# Build a release .dmg of Parola.
# Default: archive, export, verify codesign, package DMG. The notarize/staple/sign-update
# steps print at the end as manual reminders.
# With --ship: also notarize, staple, sign the Sparkle update, and add the item to appcast.xml.
# See RELEASING.md for the full release ritual.

set -euo pipefail

cd "$(dirname "$0")/.."

SHIP=0
VERSION=""
NOTARY_PROFILE="parola-notarize"
for arg in "$@"; do
  case "$arg" in
    --ship) SHIP=1 ;;
    --notary-profile=*) NOTARY_PROFILE="${arg#--notary-profile=}" ;;
    -h|--help)
      cat <<EOF
Usage: scripts/release.sh [VERSION] [--ship] [--notary-profile=<keychain-profile>]

Without --ship the script stops after building a signed DMG and prints the
remaining manual steps. With --ship the script runs the full pipeline:

  archive → export → codesign verify → DMG → notarize (--wait) → staple →
  sign-update → append the release to appcast.xml.

VERSION defaults to MARKETING_VERSION in ParolaApp/project.yml.
--notary-profile defaults to "parola-notarize". Set it up with
'xcrun notarytool store-credentials parola-notarize ...' — see RELEASING.md.
EOF
      exit 0
      ;;
    -*) ;;
    *) VERSION="$arg" ;;
  esac
done

if [ -z "$VERSION" ]; then
  VERSION=$(grep -E 'MARKETING_VERSION:' ParolaApp/project.yml | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
fi

TEAM_ID=$(grep -E '^[[:space:]]+DEVELOPMENT_TEAM:' ParolaApp/project.yml | head -1 | sed -E 's/.*"([^"]*)".*/\1/')
if [ -z "$TEAM_ID" ]; then
  echo "✘ DEVELOPMENT_TEAM is empty in ParolaApp/project.yml."
  echo "  Set it to your Apple Developer team ID before running this script."
  echo "  See RELEASING.md."
  exit 1
fi

SIGN_IDENTITY=$(grep -E '^[[:space:]]+CODE_SIGN_IDENTITY:' ParolaApp/project.yml | head -1 | sed -E 's/.*"([^"]*)".*/\1/')
if [ -z "$SIGN_IDENTITY" ] || [ "$SIGN_IDENTITY" = "-" ]; then
  echo "✘ CODE_SIGN_IDENTITY is unset or ad-hoc ('-') in ParolaApp/project.yml."
  echo "  Set it to your Developer ID Application certificate before releasing."
  echo "  Run: security find-identity -v -p codesigning"
  exit 1
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

cat > "$DIST/exportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
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

echo "▶ Building parola + parola-mcp (release, arm64)…"
(cd ParolaCore && swift build -c release --arch arm64 --product parola >/dev/null)
(cd ParolaCore && swift build -c release --arch arm64 --product parola-mcp >/dev/null)
BIN_DIR=$(cd ParolaCore && swift build -c release --arch arm64 --show-bin-path)

echo "▶ Bundling CLI + MCP into the app…"
cp "$BIN_DIR/parola" "$BIN_DIR/parola-mcp" "$APP_PATH/Contents/MacOS/"

# The CLI records from the mic; hardened runtime denies that without the entitlement.
cat > "$DIST/cli-entitlements.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key>
    <true/>
</dict>
</plist>
PLIST
codesign --force --options runtime --timestamp \
  --entitlements "$DIST/cli-entitlements.plist" \
  --sign "$SIGN_IDENTITY" "$APP_PATH/Contents/MacOS/parola"
codesign --force --options runtime --timestamp \
  --sign "$SIGN_IDENTITY" "$APP_PATH/Contents/MacOS/parola-mcp"

# Adding binaries broke the bundle seal; re-sign the app with its own entitlements.
codesign -d --entitlements - --xml "$APP_PATH" > "$DIST/app-entitlements.plist"
codesign --force --options runtime --timestamp \
  --entitlements "$DIST/app-entitlements.plist" \
  --sign "$SIGN_IDENTITY" "$APP_PATH"

echo "▶ Verifying code signature…"
if ! codesign --verify --deep --strict --verbose=2 "$APP_PATH" 2>&1; then
  echo "✘ Code signature verification failed. The exported app is not properly signed."
  echo "  Sparkle will reject the update and Gatekeeper will block it."
  exit 1
fi

if [ "$SHIP" -eq 0 ]; then
  if ! spctl --assess --type execute --verbose "$APP_PATH" 2>&1; then
    echo "ℹ Gatekeeper assessment failed locally. This is expected before notarization."
  fi
fi

if command -v create-dmg >/dev/null 2>&1; then
  create-dmg --volname "Parola $VERSION" --window-size 540 380 --icon-size 96 --app-drop-link 380 200 "$DMG" "$APP_PATH"
else
  hdiutil create -volname "Parola $VERSION" -srcfolder "$APP_PATH" -ov -format UDZO "$DMG"
fi

if [ "$SHIP" -eq 0 ]; then
  echo
  echo "✓ Built $DMG (signed and verified)"
  echo
  echo "Next steps (manual, or re-run with --ship):"
  echo "  1. Notarize:    xcrun notarytool submit \"$DMG\" --keychain-profile $NOTARY_PROFILE --wait"
  echo "  2. Staple:      xcrun stapler staple \"$DMG\""
  echo "  3. Sign Sparkle update with your private EdDSA key:"
  echo "       ./scripts/sign-update.sh \"$DMG\""
  echo "  4. Upload $DMG and add its item to appcast.xml (--ship does this for you)."
  exit 0
fi

echo
echo "▶ Notarizing $DMG via $NOTARY_PROFILE (this can take a few minutes)…"
if ! xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait; then
  echo "✘ Notarization failed. Inspect the submission log:"
  echo "    xcrun notarytool history --keychain-profile $NOTARY_PROFILE"
  exit 1
fi

echo "▶ Stapling notarization ticket…"
if ! xcrun stapler staple "$DMG"; then
  echo "✘ stapler failed. The DMG is notarized but offline installs will see Gatekeeper warnings."
  exit 1
fi

if ! spctl --assess --type execute --verbose "$APP_PATH" 2>&1; then
  echo "✘ Gatekeeper still rejects the app post-notarization. Aborting."
  exit 1
fi

echo "▶ Signing Sparkle update…"
SIGN_OUTPUT=$(./scripts/sign-update.sh "$DMG" 2>&1)
echo "$SIGN_OUTPUT"
ED_SIG=$(echo "$SIGN_OUTPUT" | grep -oE 'sparkle:edSignature="[^"]+"' | head -1 || true)
LENGTH=$(echo "$SIGN_OUTPUT" | grep -oE 'length="[^"]+"' | head -1 || true)
if [ -z "$ED_SIG" ]; then
  echo "✘ Could not extract sparkle:edSignature from sign-update output. Re-run scripts/sign-update.sh manually."
  exit 1
fi

PUB_DATE=$(date -u +"%a, %d %b %Y %H:%M:%S %z")
DMG_NAME=$(basename "$DMG")

# sparkle:version is compared against the installed app's CFBundleVersion, so it must be
# the build number, not the marketing version, or Sparkle never sees the update as newer.
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PATH/Contents/Info.plist")
if [ -z "$BUILD" ]; then
  echo "✘ Could not read CFBundleVersion from $APP_PATH/Contents/Info.plist."
  exit 1
fi
MIN_OS=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$APP_PATH/Contents/Info.plist")

ITEM=$(cat <<APPCAST
        <item>
            <title>Version $VERSION</title>
            <pubDate>$PUB_DATE</pubDate>
            <sparkle:version>$BUILD</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
            <enclosure
                url="https://github.com/stefanovalloncini/Parola/releases/download/v$VERSION/$DMG_NAME"
                $ED_SIG
                $LENGTH
                type="application/octet-stream" />
        </item>
APPCAST
)

APPCAST_FILE="appcast.xml"
ITEM_MARKER="<!-- New items go directly below this line, newest first. -->"

if [ ! -f "$APPCAST_FILE" ]; then
  cat > "$APPCAST_FILE" <<SKELETON
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>Parola</title>
        <link>https://github.com/stefanovalloncini/Parola/releases/latest/download/appcast.xml</link>
        <description>Updates for Parola.</description>
        <language>en</language>
        $ITEM_MARKER
    </channel>
</rss>
SKELETON
  echo "▶ Created $APPCAST_FILE"
fi

if grep -qF "<title>Version $VERSION</title>" "$APPCAST_FILE"; then
  echo "✘ $APPCAST_FILE already has an item for $VERSION. Remove it before re-releasing."
  exit 1
fi

if ! grep -qF "$ITEM_MARKER" "$APPCAST_FILE"; then
  echo "✘ $APPCAST_FILE is missing the insertion marker:"
  echo "    $ITEM_MARKER"
  echo "  Add it back inside <channel>, or append this item by hand:"
  echo "$ITEM"
  exit 1
fi

ITEM_FILE=$(mktemp)
printf '%s\n' "$ITEM" > "$ITEM_FILE"
sed "/New items go directly below/r $ITEM_FILE" "$APPCAST_FILE" > "$APPCAST_FILE.tmp"
mv "$APPCAST_FILE.tmp" "$APPCAST_FILE"
rm -f "$ITEM_FILE"

if ! grep -qF "<title>Version $VERSION</title>" "$APPCAST_FILE"; then
  echo "✘ Failed to insert the $VERSION item into $APPCAST_FILE. Add it by hand:"
  echo "$ITEM"
  exit 1
fi

echo
echo "✓ Shipped Parola $VERSION (build $BUILD)."
echo "✓ Added the $VERSION item to $APPCAST_FILE."
echo
echo "Next:"
echo "  git add $APPCAST_FILE && git commit -m \"appcast: $VERSION\" && git push"
echo "  gh release create v$VERSION \"$DMG\" $APPCAST_FILE --title \"$VERSION\" --notes-from-tag"
