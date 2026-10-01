import AppKit
import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@Suite("Stage states")
struct StageStateTests {
    @Test("each session state has one Stage look")
    func modes() {
        #expect(StageMode.for(.arming(.countIn(remaining: 2)), isStreaming: false) == .countIn(2))
        #expect(StageMode.for(.arming(.preparingModel(name: "Whisper Turbo", download: 0.42)), isStreaming: true)
            == .preparing("Whisper Turbo", 0.42))
        #expect(StageMode.for(.arming(.startingCapture), isStreaming: false) == .starting)
        #expect(StageMode.for(.recording, isStreaming: true) == .live)
        #expect(StageMode.for(.paused(since: Date()), isStreaming: false) == .paused)
        #expect(StageMode.for(.finishing, isStreaming: false) == .finishing)
        #expect(StageMode.for(.transcribing(progress: 0.5), isStreaming: false) == .transcribing(0.5))
        #expect(StageMode.for(.done(entryID: "E"), isStreaming: false) == .landing)
        #expect(StageMode.for(.failed(message: "The microphone stopped."), isStreaming: false)
            == .failed("The microphone stopped."))
    }

    @Test("a session reads its own mode")
    func sessionMode() {
        var take = RecordingSession(
            takeID: 1, source: .microphone, category: .transcription, title: "R", isStreaming: false, arming: .countIn(remaining: 3)
        )
        #expect(take.mode == .countIn(3))
        _ = take.markCapturing(at: Date())
        #expect(take.mode == .live)
    }

    @Test("a paused clock blinks at half a hertz: a second full, a second dimmed")
    func pausedBlink() {
        #expect(PausedBlink.opacity(at: 0) == 1)
        #expect(PausedBlink.opacity(at: 0.99) == 1)
        #expect(PausedBlink.opacity(at: 1) == PausedBlink.dimmed)
        #expect(PausedBlink.opacity(at: 1.99) == PausedBlink.dimmed)
        #expect(PausedBlink.opacity(at: 2) == 1)
        #expect(PausedBlink.opacity(at: 3.5) == PausedBlink.dimmed)
        #expect(PausedBlink.dimmed > 0, "the time stays readable through the dim half")
    }

    @Test("the time slot names the model a live take waits on, with its download")
    func preparingLine() {
        #expect(StageTimeSlot.preparingText(name: "openai_whisper-large-v3_turbo", download: 0.42) == "Preparing Whisper Turbo · 42%")
        #expect(StageTimeSlot.preparingText(name: "openai_whisper-large-v3_turbo", download: nil) == "Preparing Whisper Turbo…")
    }
}

// Closures inside #expect/#require arguments can share a symbol with a later closure in the same test (Swift 6.4); bind waits first.
extension TranscriberMockSuites {
    @MainActor
    @Suite("Stage state flows", .serialized)
    struct StageStateFlowTests {
        private static let pinnedModel = "openai_whisper-tiny"

        private func makeModel(_ label: String) -> AppModel {
            let model = makeRecordingModel(label)
            model.useStreaming = false
            model.selectedModel = Self.pinnedModel
            return model
        }

        /// A live take held while its model "loads", so it stays arming until the gate opens.
        private func startPreparingTake(_ model: AppModel, gate: MockTranscriberGate) async {
            MockStreamingTranscriberRegistry.shared.install(MockTranscriberResponse(
                partials: ["hello"], downloadFractions: [0.5], delayMs: 5_000, gate: gate
            ))
            model.useStreaming = true
            model.startRecording(source: .microphone)
            await waitUntil { model.activeTake?.captureRequested == true }
        }

        @Test("the Stage's Cancel ends a count-in with no word")
        func cancelDuringCountIn() {
            let model = makeModel("stage-cancel-count-in")
            model.recordingCountInSeconds = 60
            model.startRecording(source: .microphone)
            #expect(model.recordingCountdown == 60)
            #expect(model.route == .recording)

            model.cancelArmingTake()

            #expect(model.recording == nil)
            #expect(model.recordingCountdown == nil)
            #expect(model.exportNotice == nil)
            #expect(model.phase == .idle)
        }

        @Test("the Stage's Cancel ends a take still loading its model with no word")
        func cancelWhilePreparing() async throws {
            try await withMocksCleared([.audioSource, .streaming]) {
                await MockAudioSourceRegistry.shared.clear()
                let model = makeModel("stage-cancel-preparing")
                let gate = MockTranscriberGate()
                await startPreparingTake(model, gate: gate)
                let preparing = await waitUntil { model.recording?.mode == .preparing(Self.pinnedModel, 0.5) }
                #expect(preparing)

                model.cancelArmingTake()

                #expect(model.recording == nil)
                #expect(model.exportNotice == nil)
                let released = await waitUntil { !model.recordingActive }
                #expect(released)
                await gate.open()
                await settle()
                #expect(model.recording == nil)
                #expect(model.phase == .idle)
                let saved = await model.library.list()
                #expect(saved.isEmpty)
            }
        }
    }
}
