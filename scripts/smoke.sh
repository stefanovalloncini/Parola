#!/usr/bin/env bash
# End-to-end smoke test for the parola CLI.
# Synthesizes speech, transcribes it, checks the output contains expected keywords.
set -euo pipefail

cd "$(dirname "$0")/.."

PAROLA="ParolaCore/.build/debug/parola"
if [ ! -x "$PAROLA" ]; then
  echo "Building parola..."
  (cd ParolaCore && swift build)
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

AIFF="$WORKDIR/speech.aiff"
WAV="$WORKDIR/speech.wav"
SPEECH="Hello, my name is Parola. I transcribe audio using the Whisper model on Apple Silicon."

echo "▶ Synthesizing speech..."
say -v Samantha -o "$AIFF" "$SPEECH"
afconvert -f WAVE -d LEI16@16000 -c 1 "$AIFF" "$WAV"

echo "▶ Running CLI..."
OUT="$("$PAROLA" transcribe "$WAV" --model openai_whisper-tiny --language en)"
echo "── Output ──"
echo "$OUT"
echo "────────────"

EXPECT_KEYWORDS=("Whisper" "Apple")
FAILED=0
for kw in "${EXPECT_KEYWORDS[@]}"; do
  if ! echo "$OUT" | grep -qi "$kw"; then
    echo "✘ expected keyword not in output: $kw"
    FAILED=1
  fi
done

if [ $FAILED -eq 0 ]; then
  echo "✓ smoke test passed"
else
  echo "✘ smoke test failed"
  exit 1
fi
