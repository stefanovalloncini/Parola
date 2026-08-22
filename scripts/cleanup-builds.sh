#!/usr/bin/env bash
# Wipe every Parola.app build product on this Mac, or with --keep-latest just the stale ones.
# Default mode is dry-run; pass --yes to actually delete.

set -euo pipefail

DRY_RUN=1
QUIET=0
KEEP_LATEST=0
for arg in "$@"; do
  case "$arg" in
    --yes|-y) DRY_RUN=0 ;;
    --quiet|-q) QUIET=1 ;;
    --keep-latest|-k) KEEP_LATEST=1 ;;
    --help|-h)
      cat <<EOF
Usage: cleanup-builds.sh [--keep-latest] [--yes] [--quiet]

  --keep-latest  Delete every DerivedData folder and archive except the newest of
                 each. Installed apps, ParolaCore/.build and dist/ are left alone.
  --yes, -y      Actually delete (default is dry-run).
  --quiet, -q    Only print the summary line.

Targets (full wipe):
  - /Applications/Parola.app and ~/Applications/Parola.app
  - All Parola.app instances under ~/Library/Developer/Xcode/DerivedData
  - ParolaApp-* and ParolaiOS-* DerivedData folders themselves
  - ParolaApp/build, ParolaiOS/build, ParolaCore/.build inside the repo
  - Repo-local dist/ artifacts

Note: ParolaCore/.build holds both build products AND the SwiftPM dependency
checkouts (WhisperKit, FluidAudio, swift-argument-parser). The next
'swift build' after a cleanup re-fetches them all — expect a one-off 1–2
minute resolve step. scripts/smoke.sh also rebuilds the CLI from scratch.
EOF
      exit 0 ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="$HOME/Library/Developer/Xcode/DerivedData"
ARCHIVES="$HOME/Library/Developer/Xcode/Archives"

log() { if [ "$QUIET" -eq 0 ]; then echo "$@"; fi; }

targets=()

add_if_exists() {
  if [ -e "$1" ]; then targets+=("$1"); fi
}

# All but the newest of each: `ls -t` ranks by last write, and the folder Xcode is
# currently building into is the one it wrote to last.
stale() { ls -dt "$@" 2>/dev/null | tail -n +2; }

if [ "$KEEP_LATEST" -eq 1 ]; then
  for prefix in ParolaApp ParolaiOS ParolaCore; do
    while IFS= read -r dir; do targets+=("$dir"); done < <(stale "$DERIVED/$prefix"-*)
  done
  while IFS= read -r archive; do targets+=("$archive"); done < <(stale "$ARCHIVES"/*/Parola*.xcarchive)
else
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
fi

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
