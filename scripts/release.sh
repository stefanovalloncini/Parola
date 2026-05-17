#!/usr/bin/env bash
# Build a release .dmg of Parola.
# Default: archive, export, verify codesign, package DMG. The notarize/staple/sign-update
# steps print at the end as manual reminders.
# With --ship: also notarize, staple, sign the Sparkle update, and emit the appcast item.
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
  sign-update → emit <item> XML to stdout.

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
  echo "  4. Upload $DMG and append the printed <item> to your appcast.xml."
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

echo
echo "✓ Shipped Parola $VERSION."
echo
echo "Appcast <item> (append to appcast.xml after uploading $DMG_NAME):"
echo
cat <<APPCAST
    <item>
        <title>Version $VERSION</title>
        <pubDate>$PUB_DATE</pubDate>
        <sparkle:version>$VERSION</sparkle:version>
        <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
        <enclosure
            url="https://CHANGEME/releases/$DMG_NAME"
            $ED_SIG
            $LENGTH
            type="application/octet-stream" />
    </item>
APPCAST
