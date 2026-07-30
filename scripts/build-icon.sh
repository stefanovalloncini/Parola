#!/bin/bash
# Renders the committed AppIcon PNGs. Run from the repo root: scripts/build-icon.sh [--force]
#
# build-icon.swift shares its drawing with the app via AppIconArtwork.swift. A Swift script can't
# import a sibling file, so both are compiled together here instead of run through `swift`.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bin="$(mktemp -d)/build-icon"
trap 'rm -rf "$(dirname "$bin")"' EXIT

swiftc -O -o "$bin" \
    "$root/ParolaApp/ParolaApp/AppIconArtwork.swift" \
    "$root/scripts/build-icon.swift"

cd "$root"
"$bin" "$@"
