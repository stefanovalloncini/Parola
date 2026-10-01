import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

/// The Stage's Discard… with keyboard focus, as Full Keyboard Access gives it.
private struct FocusedDiscard: View {
    @FocusState private var focused: Bool

    var body: some View {
        Button {} label: { Label("Discard…", systemImage: "xmark") }
            .buttonStyle(GlassCapsuleButtonStyle(height: StageControls.buttonHeight))
            .focusable()
            .focused($focused)
            .onAppear { focused = true }
    }
}

// Closures inside #expect/#require arguments can share a symbol with a later closure in the same test (Swift 6.4); bind waits first.
extension TranscriberMockSuites {
    @MainActor
    @Suite("Stage controls", .serialized)
    struct StageControlsTests {
        @Test("Pause pauses a recording take and the same control resumes it")
        func togglePause() async throws {
            try await withMocksCleared(.audioSource) {
                let model = makeRecordingModel("stage-toggle")
                try await startFixtureTake(model)
                StageControls.togglePause(model)
                #expect(model.recording?.isPaused == true)
                StageControls.togglePause(model)
                #expect(model.recording?.state == .recording)
                model.cancelCurrentWork()
            }
        }

        private func playerFile() -> URL {
            FileManager.default.temporaryDirectory.appendingPathComponent("stage-space-\(UUID().uuidString).m4a")
        }

        private func pressSpace(_ model: AppModel) -> Bool {
            PlaybackKeyMonitor.handle(keyCode: 49, modifiers: [], firstResponder: nil, inMainWindow: true, model: model)
        }

        @Test("Space on a recording take pauses it, and again resumes it")
        func spacePausesTheTake() async throws {
            try await withMocksCleared(.audioSource) {
                let model = makeRecordingModel("stage-space-recording")
                try await startFixtureTake(model)
                let paused = pressSpace(model)
                let pausedState = model.recording?.isPaused == true
                #expect(paused)
                #expect(pausedState)
                let resumed = pressSpace(model)
                let resumedState = model.recording?.state == .recording
                #expect(resumed)
                #expect(resumedState)
                model.cancelCurrentWork()
            }
        }

        @Test("a held Space pauses the take once; its repeats don't resume it")
        func heldSpaceTogglesOnce() async throws {
            try await withMocksCleared(.audioSource) {
                let model = makeRecordingModel("stage-space-repeat")
                try await startFixtureTake(model)
                let pressed = PlaybackKeyMonitor.handle(keyCode: 49, modifiers: [], firstResponder: nil, inMainWindow: true, model: model)
                let repeated = PlaybackKeyMonitor.handle(
                    keyCode: 49, modifiers: [], isRepeat: true, firstResponder: nil, inMainWindow: true, model: model
                )
                let stillPaused = model.recording?.isPaused == true
                #expect(pressed)
                #expect(repeated)
                #expect(stillPaused)
                model.cancelCurrentWork()
            }
        }

        @Test("with a Stage control focused, Space is the control's: the take records on and the player stays still")
        func focusedControlKeepsSpace() async throws {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 240, height: 120), styleMask: [.titled], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: FocusedDiscard())
            window.orderFront(nil)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(500))
            let responder = window.firstResponder
            #expect(PlaybackKeyMonitor.takesSpace(responder))

            try await withMocksCleared(.audioSource) {
                let model = makeRecordingModel("stage-space-focused")
                try await startFixtureTake(model)
                model.installPlayer(for: playerFile())
                let used = PlaybackKeyMonitor.handle(keyCode: 49, modifiers: [], firstResponder: responder, inMainWindow: true, model: model)
                let recording = model.recording?.state == .recording
                let rate = model.player?.rate
                #expect(!used)
                #expect(recording)
                #expect(rate == 0)
                model.cancelCurrentWork()
            }
        }

        @Test("Space during a count-in is the take's, so a transcript's player stays still")
        func spaceDuringArming() {
            let model = makeRecordingModel("stage-space-arming")
            model.recordingCountInSeconds = 3
            model.installPlayer(for: playerFile())
            model.startRecording(source: .microphone)
            #expect(model.route == .recording)
            #expect(model.recording?.isArming == true)

            #expect(pressSpace(model))
            #expect(model.player?.rate == 0)
            model.cancelRecordingCountdown()
        }

        @Test("Space while a stopped take finishes is the take's, so a transcript's player stays still")
        func spaceWhileFinishing() async throws {
            try await withMocksCleared([.audioSource, .transcriber]) {
                let model = makeRecordingModel("stage-space-finishing")
                await installMockTranscriber(segments: [(0, 0.3, "kept")])
                try await startFixtureTake(model)
                model.installPlayer(for: playerFile())
                model.stopRecordingAndTranscribe()
                let finishing = model.recording?.state == .finishing
                #expect(finishing)

                let used = pressSpace(model)
                let rate = model.player?.rate
                #expect(used)
                #expect(rate == 0)
                model.cancelCurrentWork()
            }
        }

        @Test("a confirmed Discard deletes only the take it named")
        func discardNamesItsTake() async throws {
            try await withMocksCleared(.audioSource) {
                let model = makeRecordingModel("stage-discard")
                try await startFixtureTake(model)
                let takeID = try #require(model.recording?.takeID)

                let otherTake = await StageControls.discard(takeID + 1, model: model)
                #expect(!otherTake)
                #expect(model.recording?.state == .recording)

                let discarded = await StageControls.discard(takeID, model: model)
                #expect(discarded)
                let gone = await waitUntil { model.recording == nil }
                #expect(gone)
                let saved = await model.library.list()
                #expect(saved.isEmpty)
            }
        }

        @Test("a Discard answered after Stop leaves the stopped take alone")
        func discardAfterStop() async throws {
            try await withMocksCleared([.audioSource, .transcriber]) {
                let model = makeRecordingModel("stage-discard-stopped")
                await installMockTranscriber(segments: [(0, 0.3, "kept")])
                try await startFixtureTake(model)
                let takeID = try #require(model.recording?.takeID)
                model.stopRecordingAndTranscribe()

                await StageControls.discard(takeID, model: model)
                let landed = await landedEntry(model)
                #expect(landed != nil)
            }
        }
    }
}
