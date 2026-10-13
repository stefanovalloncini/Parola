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

        @Test("a take stopped and then let go whose model fails to load still lands its audio as interrupted", .timeLimit(.minutes(1)))
        func letGoTakeKeepsItsAudioWhenTheLoadFails() async throws {
            let audio = try makeTakeWAV("let-go-load-failure")
            defer { try? FileManager.default.removeItem(at: audio) }
            try await withMocksCleared([.audioSource, .streaming]) {
                await MockAudioSourceRegistry.shared.clear()
                let gate = MockTranscriberGate()
                MockStreamingTranscriberRegistry.shared.install(MockTranscriberResponse(
                    startFailure: MockTranscriberFailure(code: .engineLoadFailed, message: "the model would not load"),
                    gate: gate,
                    recordedAudio: audio,
                    waitsForModelOnStop: true
                ))
                let model = AppModel(bootstrap: AppBootstrap(
                    mode: .test,
                    library: makeTempLibraryURL("let-go-load-failure"),
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
                await gate.open()

                var saved: [LibraryEntry] = []
                await waitUntil { saved = await model.library.list(); return !saved.isEmpty }
                #expect(saved.count == 1)
                #expect(saved.first?.title.hasSuffix("(interrupted)") == true)
                let entry = try #require(saved.first)
                #expect(try await model.library.load(entry.id).document.audioURL != nil)
            }
        }

        @Test("a stopped and let-go take with next to no audio whose model fails leaves no checkpoint or file behind", .timeLimit(.minutes(1)))
        func letGoTakeWithoutAudioLeavesNoCheckpoint() async throws {
            let library = makeTempLibraryURL("let-go-empty-failure")
            let inflight = library.appendingPathComponent("inflight", isDirectory: true)
            try FileManager.default.createDirectory(at: inflight, withIntermediateDirectories: true)
            let audio = inflight.appendingPathComponent("parola-recording-\(UUID().uuidString).wav")
            try Data(count: 44).write(to: audio)
            defer { try? FileManager.default.removeItem(at: audio) }
            try await withMocksCleared([.audioSource, .streaming]) {
                await MockAudioSourceRegistry.shared.clear()
                let gate = MockTranscriberGate()
                MockStreamingTranscriberRegistry.shared.install(MockTranscriberResponse(
                    startFailure: MockTranscriberFailure(code: .engineLoadFailed, message: "the model would not load"),
                    gate: gate,
                    recordedAudio: audio,
                    waitsForModelOnStop: true
                ))
                let model = AppModel(bootstrap: AppBootstrap(
                    mode: .test,
                    library: library,
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
                await waitUntil { model.activeRecoveryFileURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
                model.stopRecordingAndTranscribe()
                await waitUntil { await session.stopsWaitingForModelCount == 1 }
                model.cancelCurrentWork()

                await gate.open()

                await waitUntil { model.recoveryCheckpointFiles.isEmpty }
                #expect(model.recoveryHeldByTake.isEmpty)
                await waitUntil { !FileManager.default.fileExists(atPath: audio.path) }
                #expect(await model.library.list().isEmpty)
            }
        }
    }
}

extension TranscriberMockSuites {
    @MainActor
    @Suite("A take no model ran on", .serialized)
    struct UntranscribedLiveTakeTests {
        @Test("a take whose stop gave up waiting for its model lands as not transcribed, with its Transcribe action", .timeLimit(.minutes(1)))
        func takeWithoutModelLandsNotTranscribed() async throws {
            let audio = try makeTakeWAV("gave-up-on-model")
            defer { try? FileManager.default.removeItem(at: audio) }
            try await withMocksCleared([.audioSource, .streaming]) {
                await MockAudioSourceRegistry.shared.clear()
                MockStreamingTranscriberRegistry.shared.install(MockTranscriberResponse(modelName: "", recordedAudio: audio))
                let model = AppModel(bootstrap: AppBootstrap(
                    mode: .test,
                    library: makeTempLibraryURL("take-without-model"),
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

                var saved: [LibraryEntry] = []
                await waitUntil { saved = await model.library.list(); return !saved.isEmpty }
                let entry = try #require(saved.first)
                #expect(entry.title.hasSuffix("(not transcribed)"))
                let transcript = try await model.library.load(entry.id).document.transcript
                #expect(transcript.modelName.isEmpty && transcript.segments.isEmpty)
                model.loadEntry(entry.id)
                await waitUntil { model.selectedEntryID == entry.id && model.transcript != nil }
                #expect(model.transcriptIsUntranscribed, "it opens as not transcribed, with Transcribe, not as no speech")
                #expect(model.canRetranscribeSelectedEntry)
            }
        }
    }
}
