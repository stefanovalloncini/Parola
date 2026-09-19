#!/bin/bash
# Builds one demo clip for the first-run introduction. Run from anywhere:
#
#   scripts/build-intro-clip.sh <en|it> [recording] [--voice NAME]
#
# Without a recording it speaks the placeholder text with `say`. To ship a real voice instead, hand
# it the take:
#
#   scripts/build-intro-clip.sh en ~/Desktop/intro-en.wav
#   scripts/build-intro-clip.sh it ~/Desktop/intro-it.wav
#
# Any format afconvert reads works (wav, aiff, m4a, mp3). Record about twelve seconds in a quiet
# room, one take, no music, and say the placeholder words — the transcript the introduction types
# out is whatever the CLI hears, so a clean take is the whole trick.
#
# Both files land in ParolaApp/ParolaApp/Resources/Introduction/ and are committed. Re-running
# overwrites them.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

if [ ! -x ParolaCore/.build/debug/parola ]; then
    swift build --package-path ParolaCore
fi

exec scripts/build-intro-clip.swift "$@"
