#!/usr/bin/env bash
# Bump the Parola version, regenerate Xcode projects, build, test, commit, and tag.
#
# Usage: scripts/bump.sh [X.Y.Z] [--level=major|minor|patch] [--dry-run] [--skip-tests] [--yes]
#
# With no version and no --level, the bump level comes from the `Release:` trailers
# on the commits since the last tag, defaulting to patch. See docs/versioning.md.
#
# Updates:
#   ParolaCore/Sources/ParolaCore/Parola.swift   (version literal)
#   ParolaApp/project.yml                         (MARKETING_VERSION + CURRENT_PROJECT_VERSION)
#   ParolaiOS/project.yml                         (same)
#   CHANGELOG.md                                  (new section from the commit subjects)
# Regenerates both .xcodeproj files via xcodegen.
# Runs swift build, swift test, and an xcodebuild build for the macOS app.
# Commits the change with subject "release vX.Y.Z" and creates annotated tag vX.Y.Z.
#
# Does NOT push. When ready: git push --follow-tags origin main

set -euo pipefail

NEW=""
LEVEL=""
DRY_RUN=0
SKIP_TESTS=0
ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --skip-tests) SKIP_TESTS=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    --level=*) LEVEL="${arg#--level=}" ;;
    -h|--help) NEW="__help__" ;;
    -*) echo "✘ Unknown flag: $arg"; exit 2 ;;
    *) NEW="$arg" ;;
  esac
done

usage() {
  cat <<EOF
Usage: scripts/bump.sh [X.Y.Z] [--level=major|minor|patch] [--dry-run] [--skip-tests] [--yes]

  X.Y.Z         Explicit semver. Must be greater than the current version.
                Omit it to derive the next version from the commits since the last tag.
  --level=L     Force the bump level instead of reading trailers.
  --dry-run     Show the plan but don't write, commit, or tag.
  --skip-tests  Skip the swift test + xcodebuild gate. Use only if you've just run them.
  --yes         Don't ask for confirmation on a derived version.

Examples:
  scripts/bump.sh                    # derive from Release: trailers
  scripts/bump.sh --level=minor
  scripts/bump.sh 1.0.0
  scripts/bump.sh --dry-run
EOF
}

if [ "$NEW" = "__help__" ]; then usage; exit 0; fi

if [ -n "$NEW" ] && [ -n "$LEVEL" ]; then
  echo "✘ Pass either an explicit version or --level, not both."
  exit 2
fi

if [ -n "$NEW" ] && [[ ! "$NEW" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "✘ '$NEW' is not a valid semver version."
  echo
  usage
  exit 2
fi

if [ -n "$LEVEL" ] && [[ ! "$LEVEL" =~ ^(major|minor|patch)$ ]]; then
  echo "✘ --level must be major, minor, or patch."
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

for yml in ParolaApp/project.yml ParolaiOS/project.yml; do
  if ! grep -qE 'MARKETING_VERSION: +"[0-9]+\.[0-9]+\.[0-9]+"' "$yml"; then
    echo "✘ $yml does not use quoted MARKETING_VERSION (e.g. MARKETING_VERSION: \"X.Y.Z\")."
    echo "  bump.sh's sed only matches the quoted form. Fix the file first."
    exit 1
  fi
  if ! grep -qE 'CURRENT_PROJECT_VERSION: +"[0-9]+"' "$yml"; then
    echo "✘ $yml does not use quoted CURRENT_PROJECT_VERSION (e.g. CURRENT_PROJECT_VERSION: \"42\")."
    exit 1
  fi
done

CURRENT=$(grep -E 'MARKETING_VERSION:' ParolaApp/project.yml | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
IOS_CURRENT=$(grep -E 'MARKETING_VERSION:' ParolaiOS/project.yml | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
SWIFT_CURRENT=$(grep -E 'public static let version' ParolaCore/Sources/ParolaCore/Parola.swift | head -1 | sed -E 's/.*"([^"]+)".*/\1/')

if [ "$CURRENT" != "$SWIFT_CURRENT" ] || [ "$CURRENT" != "$IOS_CURRENT" ]; then
  echo "✘ Inconsistent current version:"
  echo "    ParolaApp/project.yml:  $CURRENT"
  echo "    ParolaiOS/project.yml:  $IOS_CURRENT"
  echo "    Parola.swift:           $SWIFT_CURRENT"
  echo "  Fix manually before bumping."
  exit 1
fi

LAST_TAG=$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)
if [ -n "$LAST_TAG" ]; then
  RANGE="$LAST_TAG..HEAD"
else
  RANGE="HEAD"
fi

DERIVED=0
if [ -z "$NEW" ]; then
  DERIVED=1
  COMMIT_COUNT=$(git rev-list --count "$RANGE")
  if [ "$COMMIT_COUNT" -eq 0 ]; then
    echo "✘ No commits since ${LAST_TAG:-the start of history}. Nothing to release."
    exit 1
  fi

  if [ -z "$LEVEL" ]; then
    LEVEL="patch"
    while IFS= read -r trailer; do
      case "$(echo "$trailer" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in
        major) LEVEL="major" ;;
        minor) [ "$LEVEL" = "major" ] || LEVEL="minor" ;;
        patch|"") ;;
        *) echo "ℹ Ignoring unrecognized Release: trailer value '$trailer'." ;;
      esac
    done < <(git log --format='%(trailers:key=Release,valueonly)' "$RANGE")
  fi

  MAJOR="${CURRENT%%.*}"
  REST="${CURRENT#*.}"
  MINOR="${REST%%.*}"
  PATCH="${REST#*.}"

  if [ "$MAJOR" -eq 0 ] && [ "$LEVEL" = "major" ]; then
    echo "ℹ Pre-1.0: breaking changes bump the minor. Treating major as minor."
    echo "  Declare 1.0.0 explicitly when the API is stable: scripts/bump.sh 1.0.0"
    LEVEL="minor"
  fi

  case "$LEVEL" in
    major) NEW="$((MAJOR + 1)).0.0" ;;
    minor) NEW="$MAJOR.$((MINOR + 1)).0" ;;
    patch) NEW="$MAJOR.$MINOR.$((PATCH + 1))" ;;
  esac
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
RELEASE_DATE=$(date +%Y-%m-%d)
ENTRIES=$(git log --format='- %s' "$RANGE" | grep -v '^- release v' || true)
[ -z "$ENTRIES" ] && ENTRIES="- No user-visible changes."

echo "Plan:"
echo "  $CURRENT → $NEW"
if [ "$DERIVED" -eq 1 ]; then
  echo "  level: $LEVEL (from ${LAST_TAG:-start}..HEAD, $COMMIT_COUNT commits)"
fi
echo "  build number: $BUILD (rev-count HEAD + 1)"
echo "  tag: v$NEW"
echo "  files:"
echo "    ParolaCore/Sources/ParolaCore/Parola.swift"
echo "    ParolaApp/project.yml"
echo "    ParolaiOS/project.yml"
echo "    CHANGELOG.md"
echo ""
echo "Changelog section:"
echo "$ENTRIES" | sed 's/^/  /'
echo ""

if [ "$DRY_RUN" -eq 1 ]; then
  echo "Dry run — no changes made."
  exit 0
fi

if [ "$DERIVED" -eq 1 ] && [ "$ASSUME_YES" -eq 0 ]; then
  if [ ! -t 0 ]; then
    echo "✘ Deriving a version needs confirmation. Re-run with --yes or pass X.Y.Z."
    exit 1
  fi
  printf 'Release %s? [y/N] ' "$NEW"
  read -r reply
  case "$reply" in
    [yY]|[yY][eE][sS]) ;;
    *) echo "Aborted."; exit 1 ;;
  esac
fi

sed -i '' "s/public static let version = \"[^\"]*\"/public static let version = \"$NEW\"/" \
  ParolaCore/Sources/ParolaCore/Parola.swift

for yml in ParolaApp/project.yml ParolaiOS/project.yml; do
  sed -i '' \
    -e "s/MARKETING_VERSION: \"[^\"]*\"/MARKETING_VERSION: \"$NEW\"/" \
    -e "s/CURRENT_PROJECT_VERSION: \"[^\"]*\"/CURRENT_PROJECT_VERSION: \"$BUILD\"/" \
    "$yml"
done

NEW_IN_FILE=$(grep -E 'MARKETING_VERSION:' ParolaApp/project.yml | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
if [ "$NEW_IN_FILE" != "$NEW" ]; then
  echo "✘ sed did not update MARKETING_VERSION (file still shows $NEW_IN_FILE)."
  echo "  Reverting changes."
  git checkout -- ParolaCore/Sources/ParolaCore/Parola.swift ParolaApp/project.yml ParolaiOS/project.yml
  exit 1
fi

[ -f CHANGELOG.md ] || printf '# Changelog\n' > CHANGELOG.md
OLD_SECTIONS=$(tail -n +2 CHANGELOG.md | sed -e '/./,$!d')
{
  echo "# Changelog"
  echo
  echo "## $NEW — $RELEASE_DATE"
  echo
  echo "$ENTRIES"
  if [ -n "$OLD_SECTIONS" ]; then
    echo
    echo "$OLD_SECTIONS"
  fi
} > CHANGELOG.md.tmp
mv CHANGELOG.md.tmp CHANGELOG.md

(cd ParolaApp && xcodegen generate >/dev/null)
(cd ParolaiOS && xcodegen generate >/dev/null)

if [ "$SKIP_TESTS" -eq 0 ]; then
  echo "▶ Verifying ParolaCore builds and tests pass…"
  if ! (cd ParolaCore && swift build); then
    echo "✘ swift build failed for ParolaCore. Not tagging."
    exit 1
  fi
  if ! (cd ParolaCore && swift test); then
    echo "✘ swift test failed for ParolaCore. Not tagging."
    exit 1
  fi

  echo "▶ Verifying ParolaApp builds…"
  if ! xcodebuild \
        -project ParolaApp/ParolaApp.xcodeproj \
        -scheme ParolaApp \
        -configuration Debug \
        build CODE_SIGNING_ALLOWED=NO | xcpretty; then
    echo "✘ xcodebuild failed for ParolaApp. Not tagging."
    exit 1
  fi
fi

git add \
  ParolaCore/Sources/ParolaCore/Parola.swift \
  ParolaApp/project.yml \
  ParolaiOS/project.yml \
  CHANGELOG.md

git commit -m "release v$NEW"
git tag -a "v$NEW" -m "Parola $NEW"

cat <<EOF

✔ Bumped to v$NEW (build $BUILD).

Next:
  git push --follow-tags origin main
  ./scripts/release.sh --ship        # builds, notarizes, updates appcast.xml
  gh release create v$NEW dist/Parola-$NEW.dmg appcast.xml --generate-notes
EOF
