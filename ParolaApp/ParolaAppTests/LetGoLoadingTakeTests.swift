import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

extension TranscriberMockSuites {
    @MainActor
    @Suite("A take let go while its model loads", .serialized)
    struct LetGoLoadingTakeTests {
        @Test("a take stopped while its model loads and then let go lands with its words once the model is in", .timeLimit(.minutes(1)))
        func letGoTakeLandsAfterTheLoad() async throws {
            try await withMocksCleared([.audioSource, .streaming]) {
                await MockAudioSourceRegistry.shared.clear()
                let gate = MockTranscriberGate()
                MockStreamingTranscriberRegistry.shared.install(MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "said while the model loaded")],
                    gate: gate,
                    waitsForModelOnStop: true
                ))
                let model = AppModel(bootstrap: AppBootstrap(
                    mode: .test,
                    library: makeTempLibraryURL("let-go-loading-take"),
                    defaultsOverride: temporaryDefaults(),
                    sideEffects: [],
                    filePicker: TestFilePicker(),
                    clock: ContinuousClock()
                ))
                model.recordingCountInSeconds = 0
                model.freeDiskSpaceProvider = { 50_000_000_000 }
                model.cardMetadataOperation = { _ in nil }
                model.useStreaming = true
                model.selectedModel = "openai_whisper-tiny"
                model.startRecording(source: .microphone)
                await waitUntil { model.activeTake?.captureRequested == true }
                let session = try #require(model.streamingSession as? MockStreamingTranscriber)
                session.levelMeter.record(0.5)
                await waitUntil { model.recording?.isCapturing == true }

                model.stopRecordingAndTranscribe()
                await waitUntil { await session.stopsWaitingForModelCount == 1 }
                model.cancelCurrentWork()
                #expect(model.activeTake == nil, "the cancel let the finishing take go")

                await gate.open()

                var saved: [LibraryEntry] = []
                await waitUntil { saved = await model.library.list(); return !saved.isEmpty }
                let entry = try #require(saved.first)
                #expect(try await model.library.load(entry.id).document.transcript.text == "said while the model loaded")
            }
        }
    }
}
