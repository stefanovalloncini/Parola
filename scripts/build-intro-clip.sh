#!/bin/bash
# Builds one demo clip for the first-run introduction. Run from anywhere:
#
#   scripts/build-intro-clip.sh <en|it> [recording] [--voice NAME] [--text "what the take says"]
#
# Without a recording it speaks the placeholder text with `say`. To ship a real voice instead, hand
# it the take:
#
#   scripts/build-intro-clip.sh en ~/Desktop/intro-en.wav
#   scripts/build-intro-clip.sh it ~/Desktop/intro-it.wav --text "Questa è Parola. Ascolta una parola alla volta."
#
# Any format afconvert reads works (wav, aiff, m4a, mp3). Record about twelve seconds in a quiet
# room, one take, no music, and say the placeholder words — the transcript the introduction types
# out is whatever the CLI hears, so a clean take is the whole trick. With --text each word the model
# heard takes the casing and punctuation of the reference word it matches, and the count of matches
# is printed — write the reference the way it should read on screen, since that is what ships, and
# never paste the placeholder's "Par-ola", which is only there for `say`. Without --text the only
# edit is the app's name, written "Parola" wherever it is heard.
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
