#!/usr/bin/env bash
# Bump the Parola version, regenerate Xcode projects, commit, and tag.
#
# Usage: scripts/bump.sh X.Y.Z [--dry-run]
#
# Updates:
#   ParolaCore/Sources/ParolaCore/Parola.swift   (version literal)
#   ParolaApp/project.yml                         (MARKETING_VERSION + CURRENT_PROJECT_VERSION)
#   ParolaiOS/project.yml                         (same)
# Regenerates both .xcodeproj files via xcodegen.
# Commits the change with subject "release vX.Y.Z" and creates annotated tag vX.Y.Z.
#
# Does NOT push. When ready: git push --follow-tags origin main

set -euo pipefail

NEW="${1:-}"
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
  esac
done

if [[ ! "$NEW" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  cat <<EOF
Usage: scripts/bump.sh <X.Y.Z> [--dry-run]

  X.Y.Z      Semver. Must be greater than the current version.
  --dry-run  Show the diff but don't write, commit, or tag.

Examples:
  scripts/bump.sh 0.2.0
  scripts/bump.sh 1.0.0 --dry-run
EOF
  exit 2
fi

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "✘ xcodegen not found. Install with: brew install xcodegen"
  exit 1
fi

if [ "$DRY_RUN" -eq 0 ]; then
  if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "✘ Working tree is dirty. Commit or stash first."
    git status --short
    exit 1
  fi
fi

CURRENT=$(grep -E 'MARKETING_VERSION:' ParolaApp/project.yml | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
SWIFT_CURRENT=$(grep -E 'public static let version' ParolaCore/Sources/ParolaCore/Parola.swift | head -1 | sed -E 's/.*"([^"]+)".*/\1/')

if [ "$CURRENT" != "$SWIFT_CURRENT" ]; then
  echo "✘ Inconsistent current version:"
  echo "    ParolaApp/project.yml: $CURRENT"
  echo "    Parola.swift:          $SWIFT_CURRENT"
  echo "  Fix manually before bumping."
  exit 1
fi

if [ "$CURRENT" = "$NEW" ]; then
  echo "✘ Current version is already $NEW."
  exit 1
fi

LOWER=$(printf '%s\n%s\n' "$CURRENT" "$NEW" | sort -V | head -1)
if [ "$LOWER" != "$CURRENT" ]; then
  echo "✘ New version $NEW is not greater than current $CURRENT."
  exit 1
fi

if git rev-parse "v$NEW" >/dev/null 2>&1; then
  echo "✘ Tag v$NEW already exists."
  exit 1
fi

BUILD=$(($(git rev-list --count HEAD) + 1))

echo "Plan:"
echo "  $CURRENT → $NEW"
echo "  build number: $BUILD (rev-count HEAD + 1)"
echo "  tag: v$NEW"
echo "  files:"
echo "    ParolaCore/Sources/ParolaCore/Parola.swift"
echo "    ParolaApp/project.yml"
echo "    ParolaiOS/project.yml"
echo ""

if [ "$DRY_RUN" -eq 1 ]; then
  echo "Dry run — no changes made."
  exit 0
fi

sed -i '' "s/public static let version = \"[^\"]*\"/public static let version = \"$NEW\"/" \
  ParolaCore/Sources/ParolaCore/Parola.swift

for yml in ParolaApp/project.yml ParolaiOS/project.yml; do
  sed -i '' \
    -e "s/MARKETING_VERSION: \"[^\"]*\"/MARKETING_VERSION: \"$NEW\"/" \
    -e "s/CURRENT_PROJECT_VERSION: \"[^\"]*\"/CURRENT_PROJECT_VERSION: \"$BUILD\"/" \
    "$yml"
done

(cd ParolaApp && xcodegen generate >/dev/null)
(cd ParolaiOS && xcodegen generate >/dev/null)

git add \
  ParolaCore/Sources/ParolaCore/Parola.swift \
  ParolaApp/project.yml \
  ParolaiOS/project.yml

git commit -m "release v$NEW"
git tag -a "v$NEW" -m "Parola $NEW"

cat <<EOF

✔ Bumped to v$NEW (build $BUILD).

Next:
  git push --follow-tags origin main
  ./scripts/release.sh        # builds dist/Parola-$NEW.dmg
  gh release create v$NEW dist/Parola-$NEW.dmg --generate-notes
EOF
