# Parola

Lightweight, native macOS speech-to-text. Native SwiftUI app + a command-line tool, both built on [WhisperKit](https://github.com/argmaxinc/WhisperKit) and running fully on-device on Apple Silicon.

Requires macOS 14+ on Apple Silicon.

## Repo layout

```
ParolaCore/   Swift Package — engine, types, CLI executable
ParolaApp/    macOS Xcode project (SwiftUI)
scripts/     end-to-end smoke test
```

## Building the CLI

```sh
cd ParolaCore
swift build
```

The binary lands at `ParolaCore/.build/debug/parola`.

```sh
.build/debug/parola models list
.build/debug/parola models download openai_whisper-tiny
.build/debug/parola transcribe path/to/audio.wav --model openai_whisper-tiny --language en
.build/debug/parola transcribe path/to/audio.mp3 --format srt --output out.srt
.build/debug/parola transcribe path/to/audio.mp4 --translate
.build/debug/parola record --source mic --seconds 10
```

## Building the macOS app

```sh
cd ParolaApp
xcodegen generate     # produces ParolaApp.xcodeproj
open ParolaApp.xcodeproj
```

Or from the terminal:

```sh
xcodebuild -project ParolaApp.xcodeproj -scheme ParolaApp -configuration Debug build
```

## Smoke test

```sh
scripts/smoke.sh
```

Synthesizes test speech with `say`, transcribes it with the `tiny` model, asserts expected keywords are in the output.

## Tests

```sh
cd ParolaCore && swift test

# Run the macOS app's unit tests through Xcode:
xcodebuild -project ParolaApp/ParolaApp.xcodeproj \
    -scheme ParolaApp -destination 'platform=macOS' test
```

GitHub Actions runs both suites on every push and PR (see `.github/workflows/test.yml`).

### Pre-commit hook (optional)

```sh
git config core.hooksPath .githooks
```

This runs a fast subset of `swift test` on every commit that touches Swift sources.
Skip once with `git commit --no-verify`.
