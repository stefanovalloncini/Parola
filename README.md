<p align="center">
  <img src="ParolaApp/ParolaApp/Resources/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width="120" alt="Parola icon">
</p>

<h1 align="center">Parola</h1>

<p align="center">
  On-device speech-to-text for macOS — a SwiftUI app and a CLI, both built on <a href="https://github.com/argmaxinc/WhisperKit">WhisperKit</a>.
</p>

<p align="center"><sub>Requires macOS 14+ on Apple Silicon.</sub></p>

## CLI

```sh
cd ParolaCore
swift build
.build/debug/parola models download openai_whisper-tiny
.build/debug/parola transcribe audio.wav --model openai_whisper-tiny --language en
```

## App

```sh
cd ParolaApp
xcodegen generate
open ParolaApp.xcodeproj
```
