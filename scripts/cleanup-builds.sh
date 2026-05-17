#!/usr/bin/env bash
# Wipe every Parola.app build product on this Mac.
# Default mode is dry-run; pass --yes to actually delete.

set -euo pipefail

DRY_RUN=1
QUIET=0
for arg in "$@"; do
  case "$arg" in
    --yes|-y) DRY_RUN=0 ;;
    --quiet|-q) QUIET=1 ;;
    --help|-h)
      cat <<EOF
Usage: cleanup-builds.sh [--yes] [--quiet]

  --yes, -y      Actually delete (default is dry-run).
  --quiet, -q    Only print the summary line.

Targets:
  - /Applications/Parola.app and ~/Applications/Parola.app
  - All Parola.app instances under ~/Library/Developer/Xcode/DerivedData
  - ParolaApp-* and ParolaiOS-* DerivedData folders themselves
  - ParolaApp/build, ParolaiOS/build, ParolaCore/.build inside the repo
  - Repo-local dist/ artifacts
EOF
      exit 0 ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="$HOME/Library/Developer/Xcode/DerivedData"
ARCHIVES="$HOME/Library/Developer/Xcode/Archives"

log() { [ "$QUIET" -eq 0 ] && echo "$@"; }

targets=()

add_if_exists() {
  if [ -e "$1" ]; then targets+=("$1"); fi
}

add_if_exists "/Applications/Parola.app"
add_if_exists "$HOME/Applications/Parola.app"

if [ -d "$DERIVED" ]; then
  while IFS= read -r -d '' dir; do
    targets+=("$dir")
  done < <(find "$DERIVED" -maxdepth 1 -type d \( -name "ParolaApp-*" -o -name "ParolaiOS-*" -o -name "ParolaCore-*" \) -print0)
fi

if [ -d "$ARCHIVES" ]; then
  while IFS= read -r -d '' archive; do
    targets+=("$archive")
  done < <(find "$ARCHIVES" -type d -name "Parola*.xcarchive" -print0)
fi

add_if_exists "$REPO_ROOT/ParolaApp/build"
add_if_exists "$REPO_ROOT/ParolaiOS/build"
add_if_exists "$REPO_ROOT/ParolaCore/.build"
add_if_exists "$REPO_ROOT/dist"

if [ ${#targets[@]} -eq 0 ]; then
  log "Nothing to clean."
  exit 0
fi

total_kb=0
for t in "${targets[@]}"; do
  size_kb=$(du -sk "$t" 2>/dev/null | awk '{print $1}')
  total_kb=$((total_kb + size_kb))
  size_human=$(du -sh "$t" 2>/dev/null | awk '{print $1}')
  log "  $size_human  $t"
done

total_human=$(awk -v kb=$total_kb 'BEGIN{
  if (kb > 1024*1024) printf "%.1fG", kb/1024/1024
  else if (kb > 1024) printf "%.0fM", kb/1024
  else printf "%dK", kb
}')

if [ "$DRY_RUN" -eq 1 ]; then
  log ""
  log "Would free: $total_human  (${#targets[@]} items)"
  log "Re-run with --yes to delete."
  exit 0
fi

for t in "${targets[@]}"; do
  rm -rf "$t"
done

log ""
log "Freed $total_human across ${#targets[@]} items."
