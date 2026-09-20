#!/usr/bin/env bash
# Builds this worktree's app, launches it in test mode, then runs the
# bridge-driven ScenarioTests against it.
#
#   --mock (default)  Deterministic suite driven by injected mocks; headless; CI gate.
#   --real            LOCAL pre-demo smoke. Runs the streaming + dictation scenarios
#                     through the real WhisperKit pipeline, fed real mic audio looped
#                     back through the BlackHole virtual device. Never a CI gate.
#   --keep            Leave the run's sandbox directories behind and print where they are.
#
# Every run, --real included, gets its own library, defaults domain and home directory under /tmp
# and never reads or writes the real ones — the scenarios wipe the library they are pointed at. The
# app and the test process share the same fake home, which is how the tests find the sandboxed
# bridge. --mock also gets an empty models folder and downloads nothing; --real reads the models
# folder you already use, so it needs openai_whisper-tiny installed and never writes there. On the
# way out only the instance this script launched is killed, so a Parola running next to it is left
# alone.
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="--mock"
KEEP=""
for argument in "$@"; do
  case "$argument" in
    --mock|--real) MODE="$argument" ;;
    --keep) KEEP=1 ;;
    *) echo "usage: scripts/scenarios.sh [--mock|--real] [--keep]"; exit 2 ;;
  esac
done

DD="/tmp/parola-scenario-dd"
TAG="scenario-$$"
SANDBOX="/tmp/parola-$TAG"
REAL_HOME="$HOME"  # captured before anything is handed the fake one
FAKEHOME="/tmp/parola-$TAG-home"
PORT_FILE="$FAKEHOME/Library/Caches/Parola/bridge.port"
APP_LOG="$SANDBOX/app.log"
SUITE="com.parola.Parola.$TAG"

# Spoken fixture for --real, shared with smoke.sh so the keyword asserts match.
SPEECH="Hello, my name is Parola. I transcribe audio using the Whisper model on Apple Silicon."

APP_PID=""
PLAYER_PID=""
cleanup() {
  if [ -n "$PLAYER_PID" ]; then
    kill "$PLAYER_PID" 2>/dev/null || true
    pkill -f parola-scenario-fixture 2>/dev/null || true
  fi
  if [ -n "$APP_PID" ]; then
    kill "$APP_PID" 2>/dev/null || true
  else
    pgrep -f -- "--library=$SANDBOX/library" 2>/dev/null | while read -r pid; do
      kill "$pid" 2>/dev/null || true
    done
  fi
  if [ -n "$KEEP" ]; then
    echo "Kept the sandbox: $SANDBOX (app log: $APP_LOG) and $FAKEHOME (defaults suite $SUITE)"
  else
    rm -rf "$SANDBOX" "$FAKEHOME"
    # cfprefsd writes the suite next to the user's own domains whatever the fake home says.
    defaults delete "$SUITE" 2>/dev/null || true
    rm -f "$HOME/Library/Preferences/$SUITE.plist"
  fi
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

mkdir -p "$SANDBOX" "$FAKEHOME/Library/Caches"

MODELS="$SANDBOX/models"
if [ "$MODE" = "--real" ]; then
  # The live pipeline needs weights on disk, so it reads the ones you already have. Asked of the
  # CLI rather than spelled out here, so the storage-override logic is the app's, not a guess.
  if [ ! -x ParolaCore/.build/debug/parola ]; then
    swift build --package-path ParolaCore --product parola >/dev/null
  fi
  MODELS="$(HOME="$REAL_HOME" ParolaCore/.build/debug/parola models path)"
  [ -n "$MODELS" ] || { echo "could not resolve the models folder"; exit 1; }
  echo "Models (read-only): $MODELS"
else
  mkdir -p "$MODELS"
fi

LAUNCH_ARGS+=(
  --library="$SANDBOX/library"
  --models="$MODELS"
  --defaults-suite="$SUITE"
)

echo "Sandbox: $SANDBOX (home $FAKEHOME)"
if [ "$MODE" = "--real" ]; then
  # A directly exec'd app answers the bridge but asks for the microphone as the terminal and never
  # comes to the front for the screenshot, so the run that needs both goes through LaunchServices.
  open -n --env CFFIXED_USER_HOME="$FAKEHOME" --stdout "$APP_LOG" --stderr "$APP_LOG" \
    "$APP" --args "${LAUNCH_ARGS[@]}"
  for _ in $(seq 1 40); do
    APP_PID="$(pgrep -n -f -- "--library=$SANDBOX/library" || true)"
    if [ -n "$APP_PID" ]; then break; fi
    sleep 0.25
  done
  [ -n "$APP_PID" ] || { echo "the launched app never appeared"; exit 1; }
else
  # `open` cannot hand a headless run its fake home as cheaply, and the pid is what cleanup kills.
  CFFIXED_USER_HOME="$FAKEHOME" "$APP/Contents/MacOS/Parola" "${LAUNCH_ARGS[@]}" >"$APP_LOG" 2>&1 &
  APP_PID=$!
fi

echo "Waiting for bridge…"
for _ in $(seq 1 60); do [ -f "$PORT_FILE" ] && break; sleep 0.5; done
[ -f "$PORT_FILE" ] || { echo "bridge never came up; app log tail:"; tail -30 "$APP_LOG"; exit 1; }

# --real: loop the fixture into the (BlackHole) mic for the duration of the run.
if [ "$MODE" = "--real" ]; then
  echo "Looping fixture audio into the mic…"
  ( while :; do afplay "$WAV"; done ) &
  PLAYER_PID=$!
fi

echo "Running scenarios…"
RUN_STATUS=0
# The same fake home is how the test process finds the sandboxed bridge's port file.
(cd ParolaCore && CFFIXED_USER_HOME="$FAKEHOME" PAROLA_RUN_SCENARIOS=1 \
  PAROLA_SCENARIO_BACKEND="$BACKEND" swift test --filter ScenarioTests) || RUN_STATUS=$?

# --real: grab a screenshot for the demo log (best-effort; never fails the run).
if [ "$MODE" = "--real" ]; then
  SHOT_DIR="/tmp/parola-scenarios/$(date +%Y-%m-%d-%H%M%S)"
  mkdir -p "$SHOT_DIR" 2>/dev/null || true
  screencapture -x "$SHOT_DIR/screen.png" 2>/dev/null \
    && echo "Saved screenshot to $SHOT_DIR/screen.png" \
    || echo "(screenshot skipped)"
fi

exit "$RUN_STATUS"
