#!/usr/bin/env bash
# Signs a Sparkle update with the developer's EdDSA private key.
# Requires the Sparkle binaries (sign_update) to be on PATH or in the
# Sparkle SPM checkout's bin directory.

set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "Usage: $0 <path-to-dmg-or-zip>"
  exit 1
fi

ASSET="$1"

# Try common locations for Sparkle's sign_update tool.
SIGN_UPDATE=""
for candidate in \
    "$(find ~/Library/Developer/Xcode/DerivedData -name sign_update -type f 2>/dev/null | head -1)" \
    "$(find ~/Library/Caches/org.swift.swiftpm -name sign_update -type f 2>/dev/null | head -1)" \
    /opt/homebrew/bin/sign_update \
    /usr/local/bin/sign_update; do
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    SIGN_UPDATE="$candidate"
    break
  fi
done

if [ -z "$SIGN_UPDATE" ]; then
  cat <<EOF
✘ Couldn't find Sparkle's sign_update binary.
  It comes with the Sparkle package. After your first xcodebuild, look under
  ~/Library/Developer/Xcode/DerivedData/.../SourcePackages/artifacts/sparkle/bin.

  Once located, either add it to PATH or symlink it to /opt/homebrew/bin/sign_update.
EOF
  exit 1
fi

REPO="$(cd "$(dirname "$0")/.." && pwd)"
EXPECTED_PUBKEY=$(grep -E '^[[:space:]]+SUPublicEDKey:' "$REPO/ParolaApp/project.yml" | head -1 | sed -E 's/.*"([^"]*)".*/\1/')

if [ -z "$EXPECTED_PUBKEY" ]; then
  cat <<EOF
⚠ SUPublicEDKey is empty in ParolaApp/project.yml.
  This build's Sparkle integration will not verify any signature, so signing
  this asset would only be useful for a future release that pins a real key.
  Aborting to avoid shipping a mismatched signature.
EOF
  exit 1
fi

echo "▶ Signing $ASSET with $SIGN_UPDATE"
"$SIGN_UPDATE" "$ASSET"
echo
cat <<EOF
Append the printed sparkle:edSignature attribute to your appcast.xml entry.

The signed asset must verify against the public key in your installed apps:
  SUPublicEDKey (from project.yml): $EXPECTED_PUBKEY

If you rotated keys, every existing install on the old key will reject the
update silently. Roll out a transitional release first.
EOF
