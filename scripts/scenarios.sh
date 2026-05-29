#!/usr/bin/env bash
# Builds this worktree's app, launches it in test mode, then runs the
# bridge-driven ScenarioTests against it.
#
#   --mock (default)  Deterministic suite driven by injected mocks; headless; CI gate.
#   --real            LOCAL pre-demo smoke. Runs the streaming + dictation scenarios
#                     through the real WhisperKit pipeline, fed real mic audio looped
#                     back through the BlackHole virtual device. Never a CI gate.
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:---mock}"
DD="/tmp/parola-scenario-dd"
PORT_FILE="$HOME/Library/Caches/Parola/bridge.port"

# Spoken fixture for --real, shared with smoke.sh so the keyword asserts match.
SPEECH="Hello, my name is Parola. I transcribe audio using the Whisper model on Apple Silicon."

PLAYER_PID=""
cleanup() {
  if [ -n "$PLAYER_PID" ]; then
    kill "$PLAYER_PID" 2>/dev/null || true
    pkill -f parola-scenario-fixture 2>/dev/null || true
  fi
  pkill -f 'Parola.app/Contents/MacOS/Parola' 2>/dev/null || true
}
trap cleanup EXIT

echo "Building app…"
xcodebuild -project ParolaApp/ParolaApp.xcodeproj -scheme ParolaApp -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DD" build >/tmp/parola-scenario-build.log 2>&1 \
  || { echo "app build failed; tail:"; tail -30 /tmp/parola-scenario-build.log; exit 1; }
APP="$DD/Build/Products/Debug/Parola.app"
[ -d "$APP" ] || { echo "app not found at $APP"; exit 1; }

WAV=""
LAUNCH_ARGS=(--test-mode --headless)
BACKEND="mock"

if [ "$MODE" = "--real" ]; then
  BACKEND="real"
  LAUNCH_ARGS=(--test-mode)  # keep UI visible so captions are screenshottable

  system_profiler SPAudioDataType 2>/dev/null | grep -qi blackhole \
    || { echo "BlackHole virtual audio device not found. Install it, then re-run --real:"; echo "  brew install blackhole-2ch"; exit 1; }

  cat <<'BANNER'
──────────────────────────── --real ONE-TIME SETUP ────────────────────────────
 1. System Settings → Sound: set "BlackHole 2ch" as BOTH the default OUTPUT and
    the default INPUT device, so afplay loops the fixture back into the app's mic.
 2. System Settings → Privacy & Security → Microphone: grant the Debug "Parola"
    build access (the first run will also prompt). Accessibility is NOT needed —
    in test mode dictation uses a capturing inserter, not CGEvents.
────────────────────────────────────────────────────────────────────────────────
BANNER

  # Generate the spoken fixture once (mirror smoke.sh: Samantha → 16k mono WAV).
  WAV="/tmp/parola-scenario-fixture.wav"
  if [ ! -f "$WAV" ]; then
    echo "Synthesizing fixture…"
    AIFF="$(mktemp -t parola-fixture).aiff"
    say -v Samantha -o "$AIFF" "$SPEECH"
    afconvert -f WAVE -d LEI16@16000 -c 1 "$AIFF" "$WAV"
    rm -f "$AIFF"
  fi
fi

rm -f "$PORT_FILE" "$HOME/Library/Caches/Parola/bridge.token"
pkill -f 'Parola.app/Contents/MacOS/Parola' 2>/dev/null || true
sleep 1
open "$APP" --args "${LAUNCH_ARGS[@]}"

echo "Waiting for bridge…"
for _ in $(seq 1 60); do [ -f "$PORT_FILE" ] && break; sleep 0.5; done
[ -f "$PORT_FILE" ] || { echo "bridge never came up"; exit 1; }

# --real: loop the fixture into the (BlackHole) mic for the duration of the run.
if [ "$MODE" = "--real" ]; then
  echo "Looping fixture audio into the mic…"
  ( while :; do afplay "$WAV"; done ) &
  PLAYER_PID=$!
fi

echo "Running scenarios…"
RUN_STATUS=0
(cd ParolaCore && PAROLA_RUN_SCENARIOS=1 PAROLA_SCENARIO_BACKEND="$BACKEND" swift test --filter ScenarioTests) || RUN_STATUS=$?

# --real: grab a screenshot for the demo log (best-effort; never fails the run).
if [ "$MODE" = "--real" ]; then
  SHOT_DIR="/tmp/parola-scenarios/$(date +%Y-%m-%d-%H%M%S)"
  mkdir -p "$SHOT_DIR" 2>/dev/null || true
  screencapture -x "$SHOT_DIR/screen.png" 2>/dev/null \
    && echo "Saved screenshot to $SHOT_DIR/screen.png" \
    || echo "(screenshot skipped)"
fi

exit "$RUN_STATUS"
