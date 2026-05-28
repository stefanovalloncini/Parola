#!/usr/bin/env bash
# Builds this worktree's app, launches it headless in test mode, then runs the
# bridge-driven ScenarioTests against it. Pass --real to require a virtual audio
# device (not used by the deterministic mock suite yet).
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:---mock}"
DD="/tmp/parola-scenario-dd"

echo "Building app…"
xcodebuild -project ParolaApp/ParolaApp.xcodeproj -scheme ParolaApp -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DD" build >/tmp/parola-scenario-build.log 2>&1 \
  || { echo "app build failed; tail:"; tail -30 /tmp/parola-scenario-build.log; exit 1; }
APP="$DD/Build/Products/Debug/Parola.app"
[ -d "$APP" ] || { echo "app not found at $APP"; exit 1; }

if [ "$MODE" = "--real" ]; then
  system_profiler SPAudioDataType 2>/dev/null | grep -qi blackhole \
    || { echo "BlackHole virtual audio device not found. Install it, then re-run --real:"; echo "  brew install blackhole-2ch"; exit 1; }
  echo "(--real) Note: real-audio streaming scenarios are not part of Plan 1; running the deterministic suite."
fi

PORT_FILE="$HOME/Library/Caches/Parola/bridge.port"
rm -f "$PORT_FILE" "$HOME/Library/Caches/Parola/bridge.token"
pkill -f 'Parola.app/Contents/MacOS/Parola' 2>/dev/null || true
sleep 1
open "$APP" --args --test-mode --headless
cleanup() { pkill -f 'Parola.app/Contents/MacOS/Parola' 2>/dev/null || true; }
trap cleanup EXIT

echo "Waiting for bridge…"
for _ in $(seq 1 60); do [ -f "$PORT_FILE" ] && break; sleep 0.5; done
[ -f "$PORT_FILE" ] || { echo "bridge never came up"; exit 1; }

echo "Running scenarios…"
(cd ParolaCore && swift test --filter ScenarioTests)
