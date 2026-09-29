import AppKit
import AVFoundation
import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport
import UniformTypeIdentifiers

private struct StubTake: LiveAudioSource {
    let url: URL
    func start() async throws {}
    func prepare() async throws -> URL { url }
    func cancel() async {}
}

/// A take whose file stopped taking writes partway.
private struct CutShortTake: LiveAudioSource {
    let url: URL
    func start() async throws {}
    func prepare() async throws -> URL { throw CaptureInterrupted(url: url, reason: "the disk is full") }
    func cancel() async {}
}

/// A clock whose sleeps end at once, so a limit measured on it passes immediately.
private struct InstantClock: Clock {
    typealias Instant = ContinuousClock.Instant
    var now: Instant { ContinuousClock().now }
    var minimumResolution: Duration { .zero }
    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()
        await Task.yield()
    }
}

/// A live session that failed after keeping audio but before confirming a word.
private actor AudioOnlySession: StreamingTranscriber {
    let audio: URL
    init(audio: URL) { self.audio = audio }
    func start(
        options: TranscriptionOptions,
        speakerLabeler: (any StreamingSpeakerLabeler)?,
        downloadProgress: (@Sendable (Double) -> Void)?
    ) async throws -> AsyncStream<StreamingEvent> {
        AsyncStream { $0.finish() }
    }
    func stop() async {}
    func cancel() async {}
    func currentModel() async -> String? { nil }
    func recordingAudioURL() async -> URL? { audio }
}

/// Holds a live take's last step at its cut-short check until the test lets it go.
private actor PausingSession: StreamingTranscriber {
    private var waiting: CheckedContinuation<Void, Never>?
    private(set) var reached = false
    func start(
        options: TranscriptionOptions,
        speakerLabeler: (any StreamingSpeakerLabeler)?,
        downloadProgress: (@Sendable (Double) -> Void)?
    ) async throws -> AsyncStream<StreamingEvent> {
        AsyncStream { $0.finish() }
    }
    func stop() async {}
    func cancel() async {}
    func currentModel() async -> String? { nil }
    func audioWasCutShort() async -> Bool {
        reached = true
        await withCheckedContinuation { waiting = $0 }
        return false
    }
    func release() {
        waiting?.resume()
        waiting = nil
    }
}

/// A live session whose file stopped taking writes before the take ended.
private actor CutShortSession: StreamingTranscriber {
    func start(
        options: TranscriptionOptions,
        speakerLabeler: (any StreamingSpeakerLabeler)?,
        downloadProgress: (@Sendable (Double) -> Void)?
    ) async throws -> AsyncStream<StreamingEvent> {
        AsyncStream { $0.finish() }
    }
    func stop() async {}
    func cancel() async {}
    func currentModel() async -> String? { nil }
    func audioWasCutShort() async -> Bool { true }
}

/// Remembers the names a Save panel would have suggested, and chooses nothing.
private actor NameRecordingPicker: FilePicker {
    private(set) var suggestedNames: [String] = []
    func chooseInputFiles(allowedTypes: [UTType], allowsMultiple: Bool, message: String?) async -> [URL] { [] }
    func chooseSaveDestination(suggestedName: String, allowedTypes: [UTType], message: String?) async -> URL? {
        suggestedNames.append(suggestedName)
        return nil
    }
}

/// Whether a quit asked, and the reply it handed back once the take was wound down.
@MainActor
private final class QuitReply {
    var value: Bool?
    var asked = false
}

/// What a writer that never closed its file leaves behind: the RIFF and data sizes it opened with.
private func zeroSizes(of wav: URL) throws {
    var bytes = try Data(contentsOf: wav)
    bytes.replaceSubrange(4..<8, with: Data(count: 4))
    bytes.replaceSubrange(40..<44, with: Data(count: 4))
    try bytes.write(to: wav)
}

private func makeTakeWAV(_ label: String, seconds: Double = 0.3, in directory: URL? = nil, prefix: String = "parola-trust") throws -> URL {
    let sampleRate = 16_000, channels = 1, bytesPerSample = 2
    let frames = Int(Double(sampleRate) * seconds)
    let dataBytes = frames * channels * bytesPerSample
    var data = Data()
    func ascii(_ s: String) { data.append(contentsOf: Array(s.utf8)) }
    func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    ascii("RIFF"); le32(UInt32(36 + dataBytes)); ascii("WAVE")
    ascii("fmt "); le32(16); le16(1); le16(UInt16(channels))
    le32(UInt32(sampleRate)); le32(UInt32(sampleRate * channels * bytesPerSample))
    le16(UInt16(channels * bytesPerSample)); le16(UInt16(bytesPerSample * 8))
    ascii("data"); le32(UInt32(dataBytes))
    data.append(Data(count: dataBytes))
    let folder = directory ?? FileManager.default.temporaryDirectory
    let url = folder.appendingPathComponent("\(prefix)-\(label)-\(UUID().uuidString).wav")
    try data.write(to: url)
    return url
}

extension TranscriberMockSuites {
    @MainActor
    @Suite("Recording trust", .serialized)
    struct RecordingTrustTests {

        private func makeModel(
            libraryURL: URL = makeTempLibraryURL("recording-trust"),
            clock: any Clock<Duration> = ContinuousClock()
        ) -> AppModel {
            let model = AppModel(bootstrap: AppBootstrap(
                mode: .test,
                library: libraryURL,
                defaultsOverride: temporaryDefaults(),
                sideEffects: [],
                filePicker: TestFilePicker(),
                clock: clock
            ))
            model.recordingCountInSeconds = 0
            model.freeDiskSpaceProvider = { 50_000_000_000 }
            model.cardMetadataOperation = { _ in nil }
            return model
        }

        private func entries(_ model: AppModel, count: Int) async -> [LibraryEntry] {
            var listed: [LibraryEntry] = []
            await waitUntil { listed = await model.library.list(); return listed.count >= count }
            return listed
        }

        /// A take's transcription held by the gate, so the test acts while it is running.
        private func transcribingTake(_ model: AppModel, wav: URL) async {
            model.liveSource = StubTake(url: wav)
            model.phase = .recording(source: .microphone)
            model.stopRecordingAndTranscribe()
            await waitUntil { model.phase == .transcribing(file: wav) }
        }

        private func startStreamingTake(
            _ model: AppModel,
            gate: MockTranscriberGate? = nil,
            download: Double? = nil,
            segments: [TranscriptSegmentSeed] = [],
            delayMs: Int = 5_000
        ) async {
            MockStreamingTranscriberRegistry.shared.install(MockTranscriberResponse(
                segments: segments,
                partials: ["hello"],
                downloadFractions: download.map { [$0] } ?? [],
                delayMs: delayMs,
                gate: gate
            ))
            model.useStreaming = true
            model.selectedModel = "openai_whisper-tiny"
            model.startRecording(source: .microphone)
            await waitUntil { model.phase == .recording(source: .microphone) }
        }

        // MARK: - Stopping a take's transcription

        @Test("stopping a take's transcription saves the take untranscribed and reports nothing")
        func stopTranscribingKeepsTheTake() async throws {
            let wav = try makeTakeWAV("stop")
            defer { try? FileManager.default.removeItem(at: wav) }
            try await withMocksCleared(.transcriber) {
                await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "never landed")],
                    gate: MockTranscriberGate()
                ))
                let model = makeModel()
                await transcribingTake(model, wav: wav)
                let take = try #require(model.recordedTake)
                #expect(take.file == wav)
                #expect(take.title.hasPrefix("Recording "), "the pane names the take, not its file")

                model.stopTranscribingTake()
                #expect(model.phase == .idle)

                let saved = try #require(await entries(model, count: 1).first)
                #expect(saved.title == take.title + " (not transcribed)")
                #expect(saved.manifest.originalAudioName.isEmpty == false)
                let stored = try await model.library.load(saved.id).document.transcript
                #expect(stored.modelName.isEmpty, "no model ran on it, so it opens as not transcribed")
                await settle()
                #expect(model.phase == .idle, "a stop is not a failure")
            }
        }

        @Test("a cancel from anywhere else keeps the take too, with no error")
        func cancelCurrentWorkKeepsTheTake() async throws {
            let wav = try makeTakeWAV("cancel")
            defer { try? FileManager.default.removeItem(at: wav) }
            try await withMocksCleared(.transcriber) {
                await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "never landed")],
                    gate: MockTranscriberGate()
                ))
                let model = makeModel()
                await transcribingTake(model, wav: wav)

                model.cancelCurrentWork()

                let saved = await entries(model, count: 1)
                #expect(saved.first?.title.hasSuffix("(not transcribed)") == true)
                await settle()
                #expect(model.phase == .idle)
            }
        }

        @Test("a take saved untranscribed opens as not transcribed; Transcribe fills it in and drops the note")
        func transcribeANotTranscribedTake() async throws {
            let wav = try makeTakeWAV("later")
            defer { try? FileManager.default.removeItem(at: wav) }
            try await withMocksCleared(.transcriber) {
                let gate = MockTranscriberGate()
                await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "words at last")],
                    gate: gate
                ))
                let model = makeModel()
                await transcribingTake(model, wav: wav)
                let title = try #require(model.recordedTake?.title)
                model.stopTranscribingTake()
                let saved = try #require(await entries(model, count: 1).first)

                model.loadEntry(saved.id)
                await waitUntil { model.selectedEntryID == saved.id && model.transcript != nil }
                #expect(model.transcriptIsUntranscribed, "it opens as not transcribed, not as no speech")
                #expect(model.canRetranscribeSelectedEntry)

                await gate.open()
                model.transcribeLoadedEntry()

                await waitUntil { model.transcript?.text == "words at last" }
                #expect(!model.transcriptIsUntranscribed)
                await waitUntil { model.libraryEntry(id: saved.id)?.title == title }
            }
        }

        @Test("a take whose save failed keeps its checkpoint for the next launch, out of reach of the next take's cleanup")
        func failedSaveKeepsItsCheckpoint() async throws {
            let wav = try makeTakeWAV("failed-save")
            defer { try? FileManager.default.removeItem(at: wav) }
            try await withMocksCleared(.transcriber) {
                await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "never landed")],
                    gate: MockTranscriberGate()
                ))
                let model = makeModel()
                await transcribingTake(model, wav: wav)
                await model.pendingRecoveryWrite?.value
                let checkpoint = try #require(model.activeRecoveryFileURL)
                model.beforeLandingSave = { throw URLError(.cannotWriteToFile) }

                model.stopTranscribingTake()
                await waitUntil { !model.hasPendingTakeWork }

                #expect(await model.library.list().isEmpty)
                #expect(FileManager.default.fileExists(atPath: checkpoint.path))
                #expect(model.activeRecoveryGeneration == nil)
                model.endActiveRecovery()
                #expect(FileManager.default.fileExists(atPath: checkpoint.path), "a cancelled take's cleanup can't reach it")
            }
        }

        @Test("Retry of a take whose save failed runs from its working file and retires the checkpoint that save left")
        func retryRetiresTheFailedSavesCheckpoint() async throws {
            let wav = try makeTakeWAV("retry-failed-save")
            defer { try? FileManager.default.removeItem(at: wav) }
            try await withMocksCleared(.transcriber) {
                await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                    failure: MockTranscriberFailure(code: .transcriptionFailed, message: "engine boom")
                ))
                let model = makeModel()
                model.beforeLandingSave = { throw URLError(.cannotWriteToFile) }
                model.liveSource = StubTake(url: wav)
                model.phase = .recording(source: .microphone)
                model.stopRecordingAndTranscribe()
                await waitUntil {
                    if case .failed = model.phase { return !model.hasPendingTakeWork }
                    return false
                }
                #expect(model.recoveryCheckpointFiles.count == 1, "the failed save left its checkpoint")

                model.beforeLandingSave = nil
                await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "second time lucky")]
                ))
                await model.unloadTranscriptionSession()
                model.retryFailedTake()

                let saved = await entries(model, count: 1)
                #expect(saved.count == 1)
                #expect(await waitUntil { model.recoveryCheckpointFiles.isEmpty })
            }
        }

        @Test("a cancellation never reaches the screen as its type name")
        func cancellationReadsPlainly() {
            let message = AppModel.transcriptionFailureMessage(for: CancellationError())
            #expect(!message.contains("CancellationError"))
            #expect(message == "Transcription stopped.")
        }

        @Test("a take stopped before transcribing keeps its checkpoint until its entry exists")
        func checkpointOutlivesTheSaveOnly() async throws {
            let wav = try makeTakeWAV("checkpoint", seconds: 3)
            defer { try? FileManager.default.removeItem(at: wav) }
            try await withMocksCleared(.transcriber) {
                await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "never landed")],
                    gate: MockTranscriberGate()
                ))
                let model = makeModel()
                await transcribingTake(model, wav: wav)
                await model.pendingRecoveryWrite?.value
                #expect(model.recoveryCheckpointFiles.count == 1, "the capture's checkpoint handed over to the transcription's")

                model.stopTranscribingTake()

                var savedWithoutCheckpointFirst = false
                await waitUntil {
                    let checkpointGone = model.recoveryCheckpointFiles.isEmpty
                    let saved = await !model.library.list().isEmpty
                    if checkpointGone, !saved { savedWithoutCheckpointFirst = true }
                    return saved
                }
                #expect(!savedWithoutCheckpointFirst, "the checkpoint went before the take was in the library")
                await waitUntil { model.recoveryCheckpointFiles.isEmpty }
            }
        }

        @Test("a checkpoint a save still needs stays through cleanup, and goes when the save releases it")
        func heldCheckpointSurvivesCleanup() async throws {
            let model = makeModel()
            let generation = model.beginRecordingRecovery()
            model.liveRecordingAudioURL = URL(fileURLWithPath: "/tmp/parola-held-checkpoint.wav")
            model.writeRecordingCheckpoint()
            await model.pendingRecoveryWrite?.value
            let file = try #require(model.activeRecoveryFileURL)
            model.recoveryHeldByTake.insert(generation)

            model.endActiveRecovery()
            #expect(FileManager.default.fileExists(atPath: file.path))

            model.recoveryHeldByTake.remove(generation)
            model.endRecovery(generation)
            #expect(!FileManager.default.fileExists(atPath: file.path))
        }

        // MARK: - Recording while a take transcribes

        @Test("recording while a take transcribes starts at once and keeps that take, untranscribed, with a notice")
        func recordNowKeepsTheTranscribingTake() async throws {
            let fixture = try makeTakeWAV("takes")
            defer { try? FileManager.default.removeItem(at: fixture) }
            try await withMocksCleared([.transcriber, .audioSource]) {
                await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "the first take")],
                    gate: MockTranscriberGate()
                ))
                await MockAudioSourceRegistry.shared.install(kind: .mic, fixtureURL: fixture)
                let model = makeModel()
                model.useStreaming = false
                model.pendingRecordingCategory = .meeting
                model.startRecording(source: .microphone)
                await waitUntil { model.liveSource != nil }
                model.stopRecordingAndTranscribe()
                await waitUntil { if case .transcribing = model.phase { return true }; return false }

                model.startRecording(source: .microphone)
                await waitUntil { model.phase == .recording(source: .microphone) && model.liveSource != nil }
                #expect(model.activeTake?.category == .transcription, "the new take carries its own category")

                let first = try #require(await entries(model, count: 1).first)
                #expect(first.title.hasSuffix("(not transcribed)"))
                #expect(first.category == .meeting, "the stopped take keeps its own category")
                await waitUntil { model.exportNotice != nil }
                #expect(model.exportNotice?.message == "Saved the previous recording without transcribing it.")
                #expect(model.phase == .recording(source: .microphone), "the save never takes the new take's pane")

                model.cancelCurrentWork()
            }
        }

        @Test("opening a file while a take transcribes keeps the take, untranscribed, and says so")
        func fileOpenKeepsTheTranscribingTake() async throws {
            let wav = try makeTakeWAV("take-then-file")
            let file = try makeTakeWAV("users-file")
            defer {
                try? FileManager.default.removeItem(at: wav)
                try? FileManager.default.removeItem(at: file)
            }
            try await withMocksCleared(.transcriber) {
                await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "never landed")],
                    gate: MockTranscriberGate()
                ))
                let model = makeModel()
                await transcribingTake(model, wav: wav)

                model.transcribe(fileURL: file)

                let kept = try #require(await entries(model, count: 1).first)
                #expect(kept.title.hasSuffix("(not transcribed)"))
                await waitUntil { model.exportNotice != nil }
                #expect(model.exportNotice?.message == "Saved the previous recording without transcribing it.")
                model.cancelCurrentWork()
            }
        }

        // MARK: - A take's category and targets

        @Test("a take keeps the category and app targets it started with, whatever is asked for later")
        func takeKeepsItsCategoryAndTargets() async throws {
            let fixture = try makeTakeWAV("meeting")
            defer { try? FileManager.default.removeItem(at: fixture) }
            try await withMocksCleared([.audioSource, .transcriber]) {
                await MockAudioSourceRegistry.shared.install(kind: .system, fixtureURL: fixture)
                await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "meeting words")]
                ))
                let model = makeModel()
                model.meetingCaptureAppOnly = true

                model.startMeetingRecording(appName: "Microsoft Teams")
                await waitUntil { model.liveSource != nil }
                let teams: Set<String> = ["com.microsoft.teams", "com.microsoft.teams2"]
                #expect(model.activeTake?.category == .meeting)
                #expect(model.activeTake?.captureTargets == teams)

                model.startMeetingRecording(appName: "Zoom")
                #expect(model.activeTake?.captureTargets == teams, "a refused request never reaches the running take")
                #expect(model.pendingRecordingCategory == .transcription)
                #expect(model.pendingCaptureBundleIDs == nil)

                model.stopRecordingAndTranscribe()
                let saved = try #require(await entries(model, count: 1).first)
                #expect(saved.category == .meeting)
                #expect(saved.title.hasPrefix("Meeting "))
            }
        }

        // MARK: - Arming

        @Test("a live take arms until its first event, then starts its clock", .timeLimit(.minutes(1)))
        func armingThenRecording() async throws {
            try await withMocksCleared([.audioSource, .streaming]) {
                await MockAudioSourceRegistry.shared.clear()
                let gate = MockTranscriberGate()
                let model = makeModel()
                await startStreamingTake(model, gate: gate, download: 0.42)

                await waitUntil {
                    model.takeArming == .preparingModel(name: "openai_whisper-tiny", download: 0.42)
                }
                #expect(model.recordingStartedAt == nil)
                #expect(!model.takeInProgress, "nothing captured yet, so quitting asks nothing")

                await gate.open()
                await waitUntil { model.recordingStartedAt != nil }
                #expect(model.takeArming == nil)
                #expect(model.takeInProgress)

                model.cancelCurrentWork()
                await waitUntil { model.recordingLevelMeter == nil }
                #expect(model.recordingStartedAt == nil)
            }
        }

        @Test("finishing a take while its model loads ends it at once and says nothing was recorded", .timeLimit(.minutes(1)))
        func finishWhileArmingSaysSo() async throws {
            try await withMocksCleared([.audioSource, .streaming]) {
                await MockAudioSourceRegistry.shared.clear()
                let model = makeModel()
                await startStreamingTake(model, gate: MockTranscriberGate(), download: 0.5)
                await waitUntil { model.takeArming != nil }

                model.stopRecordingAndTranscribe()

                let expected = AppModel.nothingRecordedMessage(for: .preparingModel(name: "openai_whisper-tiny", download: nil))
                #expect(expected == "Nothing was recorded — the model was still loading.")
                #expect(model.phase == .failed(message: expected))
                await waitUntil { !model.recordingActive }
                await settle()
                #expect(model.phase == .failed(message: expected), "the load finishing later must not replace the message")
                #expect(await model.library.list().isEmpty)
            }
        }

        @Test("Cancel while a take arms goes home without a word, and Record works again at once", .timeLimit(.minutes(1)))
        func cancelWhileArmingIsQuiet() async throws {
            try await withMocksCleared([.audioSource, .streaming]) {
                await MockAudioSourceRegistry.shared.clear()
                let model = makeModel()
                await startStreamingTake(model, gate: MockTranscriberGate(), download: 0.5)
                await waitUntil { model.takeArming != nil }

                model.cancelRecordingBeforeCapture()

                #expect(model.phase == .idle)
                #expect(!model.recordingActive, "a cancelled take doesn't hold the next one back")
                await settle()
                #expect(model.phase == .idle)
                #expect(model.takeArming == nil)
            }
        }

        @Test("Cancel while a take arms leaves an older take's held checkpoint on disk", .timeLimit(.minutes(1)))
        func armingCancelSparesAnOlderCheckpoint() async throws {
            try await withMocksCleared([.audioSource, .streaming]) {
                await MockAudioSourceRegistry.shared.clear()
                let model = makeModel()
                let older = model.beginFileTranscribeRecovery(
                    sourceURL: URL(fileURLWithPath: "/tmp/parola-older-take.wav"), title: "Recording 1", source: .microphone
                )
                await model.pendingRecoveryWrite?.value
                let olderFile = try #require(model.activeRecoveryFileURL)
                model.recoveryHeldByTake.insert(older)

                await startStreamingTake(model, gate: MockTranscriberGate(), download: 0.5)
                await waitUntil { model.takeArming != nil }
                model.cancelRecordingBeforeCapture()
                await settle()

                #expect(FileManager.default.fileExists(atPath: olderFile.path), "the older take's save still needs its checkpoint")
                model.recoveryHeldByTake.remove(older)
                model.endRecovery(older)
            }
        }

        @Test("events a finished take's session still sends never reach the take recording now", .timeLimit(.minutes(1)))
        func staleTakeEventsSpareTheNewTake() async throws {
            try await withMocksCleared([.audioSource, .streaming]) {
                await MockAudioSourceRegistry.shared.clear()
                let model = makeModel()
                await startStreamingTake(model)
                await waitUntil { model.recordingStartedAt != nil }
                let startedAt = model.recordingStartedAt
                let ended = AppModel.TakeContext(id: -1, source: .microphone, category: .transcription, captureTargets: [])

                await model.handleStreamingEvent(.partial(text: "an older take"), take: ended)
                await model.handleStreamingEvent(.finished(Transcript(
                    segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "an older take")],
                    language: "en", modelName: "mock"
                )), take: ended)

                #expect(model.phase == .recording(source: .microphone))
                #expect(model.recordingStartedAt == startedAt)
                #expect(model.livePartialText != "an older take")
                #expect(model.takeInProgress)
                await settle()
                #expect(await model.library.list().isEmpty)
                model.cancelCurrentWork()
            }
        }

        @Test("a live take that lands after a cancel is saved without touching the screen the cancel left", .timeLimit(.minutes(1)))
        func lateLandingLeavesTheScreen() async throws {
            try await withMocksCleared([.audioSource, .streaming]) {
                await MockAudioSourceRegistry.shared.clear()
                let model = makeModel()
                await startStreamingTake(model)
                await waitUntil { model.recordingStartedAt != nil }
                let take = try #require(model.activeTake)
                let session = PausingSession()
                let words = Transcript(
                    segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "late words")], language: "en", modelName: "mock"
                )

                let landing = Task { await model.handleStreamingEvent(.finished(words), take: take, session: session) }
                await waitUntil { await session.reached }
                model.cancelCurrentWork()
                await session.release()
                await landing.value

                #expect(model.phase == .idle, "the screen stays as the cancel left it")
                #expect(model.transcript?.text != "late words")
                let saved = try #require(await entries(model, count: 1).first)
                #expect(try await model.library.load(saved.id).document.transcript.text == "late words")
            }
        }

        // MARK: - The take's clock

        @Test("the take's clock and levels live on the model, so a page change keeps them")
        func clockSurvivesARouteChange() async throws {
            let fixture = try makeTakeWAV("clock")
            defer { try? FileManager.default.removeItem(at: fixture) }
            try await withMocksCleared(.audioSource) {
                await MockAudioSourceRegistry.shared.install(kind: .mic, fixtureURL: fixture)
                let model = makeModel()
                model.useStreaming = false
                model.startRecording(source: .microphone)
                await waitUntil { model.recordingStartedAt != nil }
                let startedAt = try #require(model.recordingStartedAt)
                let trace = try #require(model.recordingLevelTrace)

                model.route = .statistics
                await settle(for: .milliseconds(50))
                model.route = .transcript

                #expect(model.recordingStartedAt == startedAt)
                #expect(model.recordingLevelTrace === trace)
                #expect(AppDelegate.recordingBadge(startedAt: startedAt, now: startedAt.addingTimeInterval(75)) == "1:15")

                model.cancelCurrentWork()
            }
        }

        @Test("the Dock badge waits while a take arms and turns over with the take's own seconds")
        func dockBadgeReadsTheTakeClock() {
            let start = Date(timeIntervalSinceReferenceDate: 1_000)
            #expect(AppDelegate.recordingBadge(startedAt: nil, now: start) == "…")
            #expect(AppDelegate.recordingBadge(startedAt: start, now: start.addingTimeInterval(3_725)) == "1:02:05")
            #expect(abs(AppDelegate.secondsToNextTick(startedAt: start, now: start.addingTimeInterval(2.3)) - 0.7) < 0.000_1)
            #expect(AppDelegate.secondsToNextTick(startedAt: nil, now: start) == 1)
        }

        // MARK: - Silence

        @Test("a Mac-audio take that hears nothing warns, and sound clears the warning")
        func soundClearsTheSilenceWarning() async throws {
            let silent = try makeTakeWAV("mac-audio")
            defer { try? FileManager.default.removeItem(at: silent) }
            try await withMocksCleared(.audioSource) {
                await MockAudioSourceRegistry.shared.install(kind: .system, fixtureURL: silent)
                let model = makeModel()
                model.silenceRule = AppModel.SilenceRule(microphone: 0.5, macAudioBeforeSound: 0.5, macAudioAfterSound: 60)
                model.startRecording(source: .systemAudio)
                await waitUntil { model.recordingLevelMeter != nil && model.recordingStartedAt != nil }
                #expect(AppModel.RecordSource.systemAudio.meterLabel == "Mac audio")

                // A few 750 ms ticks of the watch, and a slow host can stall the main actor for seconds.
                await waitUntil(timeoutMs: 15_000) { model.recordingIsSilent }

                model.recordingLevelMeter?.record(0.6)
                await waitUntil(timeoutMs: 15_000) { !model.recordingIsSilent }
                await settle(for: .seconds(2))
                #expect(!model.recordingIsSilent, "after sound, a Mac-audio pause shorter than a minute is just a pause")

                model.cancelCurrentWork()
            }
        }

        // MARK: - A write that fails

        @Test("a take whose file stopped taking writes keeps the audio that landed, saved as interrupted")
        func cutShortTakeKeepsItsAudio() async throws {
            let wav = try makeTakeWAV("cut-short")
            defer { try? FileManager.default.removeItem(at: wav) }
            try zeroSizes(of: wav)
            let model = makeModel()
            model.liveSource = CutShortTake(url: wav)
            model.phase = .recording(source: .microphone)

            model.stopRecordingAndTranscribe()

            let saved = try #require(await entries(model, count: 1).first)
            #expect(saved.title.hasSuffix("(interrupted)"))
            #expect(saved.manifest.originalAudioName.isEmpty == false)
            #expect(FileManager.default.fileExists(atPath: wav.path), "the take's file is never deleted")
            let kept = try #require(try await model.library.load(saved.id).document.audioURL)
            #expect(try AVAudioFile(forReading: kept).length > 0, "its header counts the audio that landed")
            await waitUntil {
                if case .failed(let message) = model.phase { return message.contains("saved to your library") }
                return false
            }
            #expect(model.failedTakeAudioURL == wav, "Retry transcribes what was kept")
        }

        @Test("a live take cut short by a write failure gets its header rewritten before it is saved")
        func cutShortLiveTakePlays() async throws {
            let wav = try makeTakeWAV("cut-live")
            defer { try? FileManager.default.removeItem(at: wav) }
            try zeroSizes(of: wav)
            let model = makeModel()
            model.phase = .recording(source: .microphone)

            await model.handleStreamingEvent(.finished(Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 0.2, text: "until the disk filled")],
                language: "en", modelName: "m", sourceURL: wav
            )), session: CutShortSession())

            let saved = try #require(await entries(model, count: 1).first)
            #expect(saved.title.hasSuffix("(interrupted)"))
            let audio = try #require(try await model.library.load(saved.id).document.audioURL)
            #expect(try AVAudioFile(forReading: audio).length > 0)
        }

        // MARK: - Titles

        @Test("a finished take is named by its title, then by its entry, never by its working file")
        func finishedTakeNeverShowsItsFileName() async throws {
            let wav = try makeTakeWAV("title")
            defer { try? FileManager.default.removeItem(at: wav) }
            try await withMocksCleared(.transcriber) {
                await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "a titled take")]
                ))
                let model = makeModel()
                model.liveSource = StubTake(url: wav)
                model.phase = .recording(source: .microphone)
                model.stopRecordingAndTranscribe()

                await waitUntil { model.phase == .ready }
                let title = try #require(model.recordedTake?.title)
                #expect(!title.contains("parola-trust"))

                await waitUntil { model.sourceFileURL != wav && model.selectedEntryID != nil }
                let entry = try #require(model.selectedEntryID.flatMap { model.libraryEntry(id: $0) })
                #expect(model.recordedTakeTitle(playing: model.sourceFileURL) == nil, "playback moved into the entry")
                #expect(AppModel.transcriptDisplayTitle(
                    sourceFileURL: model.sourceFileURL, entry: entry, showsAITitle: model.showAITitles, fallback: "Untitled"
                ) == title)
            }
        }

        @Test("a live take that failed before a word came through is saved as not transcribed, not as no speech")
        func failedLiveTakeWithoutWordsIsNotTranscribed() async throws {
            let wav = try makeTakeWAV("no-words")
            defer { try? FileManager.default.removeItem(at: wav) }
            let model = makeModel()
            model.phase = .recording(source: .microphone)

            await model.handleStreamingEvent(.failed("the engine stopped"), session: AudioOnlySession(audio: wav))

            let saved = try #require(await entries(model, count: 1).first)
            #expect(saved.title.hasSuffix("(interrupted)"))
            #expect(try await model.library.load(saved.id).document.transcript.modelName.isEmpty)
        }

        @Test("a restored recording with audio but no words opens as not transcribed")
        func restoredTakeWithoutWordsIsNotTranscribed() {
            let checkpoint = RecoveryCheckpoint(kind: .recording, startedAt: Date(), modelName: "openai_whisper-base")
            let audio = URL(fileURLWithPath: "/tmp/parola-restored.wav")
            #expect(AppModel.restoredTranscript(checkpoint, audioURL: audio)?.modelName == "")
            var withWords = checkpoint
            withWords.segments = [TranscriptSegment(id: 0, start: 0, end: 1, text: "salvato")]
            #expect(AppModel.restoredTranscript(withWords, audioURL: audio)?.modelName == "openai_whisper-base")
            #expect(AppModel.restoredTranscript(checkpoint, audioURL: nil) == nil)
        }

        @Test("a take's title and its notes read in Italian")
        func takeTitlesReadInItalian() throws {
            let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
            let italian = try #require(Bundle(path: path))
            let endedAt = Date(timeIntervalSince1970: 1_700_000_000)
            let stamp = AppFormat.dateAndTime(endedAt)

            let meeting = AppModel.liveRecordingTitle(category: .meeting, endedAt: endedAt, bundle: italian)
            #expect(meeting == "Riunione \(stamp)")
            #expect(AppModel.takeTitle(meeting, suffix: .notTranscribed, bundle: italian) == "Riunione \(stamp) (non trascritta)")
            #expect(AppModel.recoveredRecordingTitle(startedAt: endedAt, bundle: italian) == "Registrazione \(stamp) (recuperata)")
        }

        @Test("Export and Share name a take still playing from its working file by its title")
        func exportNamesAnUnsavedTakeByItsTitle() async throws {
            let wav = try makeTakeWAV("export-title")
            defer { try? FileManager.default.removeItem(at: wav) }
            try await withMocksCleared(.transcriber) {
                await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "unsaved")],
                    gate: MockTranscriberGate()
                ))
                let model = makeModel()
                await transcribingTake(model, wav: wav)
                let title = try #require(model.recordedTake?.title)

                #expect(model.currentTranscriptTitle == title)
                #expect(!model.currentTranscriptTitle.contains("parola-trust"))
                model.stopTranscribingTake()
            }
        }

        @Test("Transcribe keeps a title the user typed, note and all")
        func transcribeKeepsATypedTitle() async throws {
            let wav = try makeTakeWAV("typed-title")
            defer { try? FileManager.default.removeItem(at: wav) }
            try await withMocksCleared(.transcriber) {
                let gate = MockTranscriberGate()
                await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "words at last")],
                    gate: gate
                ))
                let model = makeModel()
                await transcribingTake(model, wav: wav)
                model.stopTranscribingTake()
                let saved = try #require(await entries(model, count: 1).first)
                try await model.library.renameEntry(saved.id, to: "Kept (not transcribed)")
                model.loadEntry(saved.id)
                await waitUntil { model.selectedEntryID == saved.id && model.transcript != nil }

                await gate.open()
                model.transcribeLoadedEntry()

                await waitUntil { model.transcript?.text == "words at last" }
                await model.awaitLandingSteps()
                #expect(await model.library.list().first?.title == "Kept (not transcribed)")
            }
        }

        @Test("Save As suggests a take's title while it still plays from its working file")
        func saveAsNamesAnUnsavedTakeByItsTitle() async throws {
            let wav = try makeTakeWAV("save-as-title")
            defer { try? FileManager.default.removeItem(at: wav) }
            try await withMocksCleared(.transcriber) {
                await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "unsaved")],
                    gate: MockTranscriberGate()
                ))
                let picker = NameRecordingPicker()
                let model = AppModel(bootstrap: AppBootstrap(
                    mode: .test, library: makeTempLibraryURL("save-as"), defaultsOverride: temporaryDefaults(),
                    sideEffects: [], filePicker: picker, clock: ContinuousClock()
                ))
                model.recordingCountInSeconds = 0
                model.freeDiskSpaceProvider = { 50_000_000_000 }
                await transcribingTake(model, wav: wav)
                model.transcript = Transcript(segments: [], language: "en", modelName: "m")
                let title = try #require(model.recordedTake?.title)

                model.saveProjectDocument()

                await waitUntil { await !picker.suggestedNames.isEmpty }
                #expect(await picker.suggestedNames == [TranscriptShareFile.safeName(for: title) + ".parola"])
                model.stopTranscribingTake()
            }
        }

        @Test("a take's title loses its not-transcribed note once it has words, in either language")
        func transcribedTitleDropsTheNote() throws {
            #expect(AppModel.transcribedTitle(from: "Recording 1 (not transcribed)") == "Recording 1")
            #expect(AppModel.transcribedTitle(from: "Meeting 2 (transcription failed)") == "Meeting 2")
            #expect(AppModel.transcribedTitle(from: "Recording 3 (interrupted)") == nil)
            #expect(AppModel.transcribedTitle(from: "Quarterly review") == nil)

            let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
            let italian = try #require(Bundle(path: path))
            #expect(AppModel.transcribedTitle(from: "Registrazione 1 (non trascritta)", bundle: italian) == "Registrazione 1")
            #expect(AppModel.transcribedTitle(from: "Recording 2 (not transcribed)", bundle: italian) == "Recording 2")
        }

        // MARK: - Working files the library never got

        /// As if this build first swept the library a day ago, so the takes a test makes count as its own.
        private func sweptBefore(_ library: URL) throws {
            let folder = library.appendingPathComponent("recovery", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try ISO8601DateFormatter().string(from: Date().addingTimeInterval(-86_400))
                .write(to: folder.appendingPathComponent("take-import-cutoff"), atomically: true, encoding: .utf8)
        }

        @Test("parola-mic files from before this build first swept keep the old rule: never imported, deleted after two days")
        func earlierMicLeftoversAreNeverImported() async throws {
            let library = makeTempLibraryURL("mic-cutoff")
            let inflight = library.appendingPathComponent("inflight", isDirectory: true)
            try FileManager.default.createDirectory(at: inflight, withIntermediateDirectories: true)
            func leftover(_ label: String, prefix: String, age: TimeInterval) throws -> URL {
                let file = try makeTakeWAV(label, seconds: 1, in: inflight, prefix: prefix)
                try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: file.path)
                return file
            }
            let dictation = try leftover("earlier-dictation", prefix: "parola-mic", age: 3_600)
            let oldDictation = try leftover("old-dictation", prefix: "parola-mic", age: 3 * 86_400)
            let systemTake = try leftover("earlier-meeting", prefix: "parola-system", age: 3_600)

            let model = makeModel(libraryURL: library)
            await model.inflightSweep?.value

            let listed = await model.library.list()
            #expect(listed.count == 1, "only the meeting take, which no dictation could have written")
            #expect(listed.first?.manifest.source == .systemAudio)
            #expect(FileManager.default.fileExists(atPath: dictation.path), "younger than two days: left for now")
            #expect(!FileManager.default.fileExists(atPath: oldDictation.path))
            #expect(!FileManager.default.fileExists(atPath: systemTake.path), "the imported take's copy goes")

            let cutoff = model.takeImportCutoff()
            let micTake = inflight.appendingPathComponent("parola-mic-\(UUID().uuidString).wav")
            #expect(AppModel.isImportableTake(micTake, modified: cutoff.addingTimeInterval(60), takesSince: cutoff), "this build's own mic takes are")
            #expect(!AppModel.isImportableTake(micTake, modified: cutoff.addingTimeInterval(-60), takesSince: cutoff))
        }

        @Test("the sweep brings back a take that never reached the library and drops copies of saved ones")
        func sweepImportsOrphanedTakes() async throws {
            let library = makeTempLibraryURL("sweep-import")
            let inflight = library.appendingPathComponent("inflight", isDirectory: true)
            try FileManager.default.createDirectory(at: inflight, withIntermediateDirectories: true)
            try sweptBefore(library)
            let orphan = try makeTakeWAV("orphan", seconds: 1, in: inflight, prefix: "parola-mic")
            let savedCopy = try makeTakeWAV("saved", seconds: 1.1, in: inflight, prefix: "parola-system")
            let fresh = try makeTakeWAV("fresh", seconds: 1.2, in: inflight, prefix: "parola-recording")
            let seed = LibraryStore(libraryURL: library, extraIndexer: nil)
            _ = try await seed.add(
                transcript: AppModel.untranscribedTranscript(of: savedCopy, language: nil),
                audioSource: savedCopy
            )
            try zeroSizes(of: orphan)
            let old = Date().addingTimeInterval(-3_600)
            for file in [orphan, savedCopy] {
                try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.path)
            }

            let model = makeModel(libraryURL: library)
            await model.inflightSweep?.value

            let listed = await model.library.list()
            #expect(listed.count == 2, "the saved take isn't imported a second time")
            let recovered = try #require(listed.first { $0.title.hasSuffix("(recovered)") })
            let document = try await model.library.load(recovered.id).document
            #expect(document.transcript.modelName.isEmpty)
            #expect(try AVAudioFile(forReading: try #require(document.audioURL)).length > 0, "a crashed take's header is rewritten so it plays")
            #expect(!FileManager.default.fileExists(atPath: orphan.path), "the orphan moved into its entry")
            #expect(!FileManager.default.fileExists(atPath: savedCopy.path))
            #expect(FileManager.default.fileExists(atPath: fresh.path), "a file written minutes ago is left alone")
        }

        @Test("the sweep leaves dictation and preview scratch out of the library, deleting it only once it is two days old")
        func sweepNeverImportsScratch() async throws {
            let library = makeTempLibraryURL("sweep-scratch")
            let inflight = library.appendingPathComponent("inflight", isDirectory: true)
            try FileManager.default.createDirectory(at: inflight, withIntermediateDirectories: true)
            func scratch(_ prefix: String, age: TimeInterval) throws -> URL {
                let url = inflight.appendingPathComponent("\(prefix)-\(UUID().uuidString).wav")
                try Data(count: 64 * 1024).write(to: url)
                try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
                return url
            }
            let oldDictation = try scratch(RecordingScratch.dictationPrefix, age: 3 * 24 * 3600)
            let recentDictation = try scratch(RecordingScratch.dictationPrefix, age: 3_600)
            let oldPreview = try scratch(RecordingScratch.previewPrefix, age: 3 * 24 * 3600)
            let folder = inflight.appendingPathComponent("not-a-take.wav", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3 * 24 * 3600)], ofItemAtPath: folder.path)

            let model = makeModel(libraryURL: library)
            await model.inflightSweep?.value

            #expect(await model.library.list().isEmpty, "scratch is never a take")
            #expect(!FileManager.default.fileExists(atPath: oldDictation.path))
            #expect(!FileManager.default.fileExists(atPath: oldPreview.path))
            #expect(FileManager.default.fileExists(atPath: recentDictation.path), "scratch from today may still be in use")
            #expect(FileManager.default.fileExists(atPath: folder.path), "only regular .wav files are swept")
        }

        @Test("the sweep leaves a stale take file alone while this session still uses it, and imports it by copy once it doesn't")
        func sweepSkipsAFileInUse() async throws {
            let library = makeTempLibraryURL("sweep-in-use")
            let inflight = library.appendingPathComponent("inflight", isDirectory: true)
            try FileManager.default.createDirectory(at: inflight, withIntermediateDirectories: true)
            try sweptBefore(library)
            let model = makeModel(libraryURL: library)
            await model.inflightSweep?.value
            let take = try makeTakeWAV("in-use", seconds: 1, in: inflight, prefix: "parola-mic")
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3_600)], ofItemAtPath: take.path)
            model.failedTakeAudioURL = take

            model.sweepInflightRecordings()
            await model.inflightSweep?.value

            #expect(FileManager.default.fileExists(atPath: take.path))
            #expect(await model.library.list().isEmpty)

            model.failedTakeAudioURL = nil
            model.sweepInflightRecordings()
            await model.inflightSweep?.value

            let imported = await model.library.list()
            #expect(imported.count == 1)
            #expect(imported.first?.manifest.originalAudioName.isEmpty == false)
            #expect(!FileManager.default.fileExists(atPath: take.path), "the original goes once the entry holds its copy")
        }

        @Test("the sweep turns a save cut off mid-write back into an entry: the whole document, or at least its audio")
        func sweepSalvagesStagingFolders() async throws {
            let library = makeTempLibraryURL("sweep-staging")
            try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
            let hourAgo = Date().addingTimeInterval(-3_600)

            let audioOnly = library.appendingPathComponent("\(UUID().uuidString).parola.tmp", isDirectory: true)
            try FileManager.default.createDirectory(at: audioOnly, withIntermediateDirectories: true)
            let take = try makeTakeWAV("staged", seconds: 1)
            try FileManager.default.moveItem(at: take, to: audioOnly.appendingPathComponent("audio.wav"))

            let words = try makeTakeWAV("staged-words", seconds: 1.1)
            defer { try? FileManager.default.removeItem(at: words) }
            let written = try ParolaDocument.write(
                transcript: Transcript(segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "almost saved")], language: "en", modelName: "m"),
                audioURL: words,
                to: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                titleOverride: "Meeting notes"
            )
            let complete = library.appendingPathComponent("\(UUID().uuidString).parola.tmp", isDirectory: true)
            try FileManager.default.moveItem(at: written, to: complete)
            for folder in [audioOnly, complete] {
                for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
                    try FileManager.default.setAttributes([.modificationDate: hourAgo], ofItemAtPath: file.path)
                }
                try FileManager.default.setAttributes([.modificationDate: hourAgo], ofItemAtPath: folder.path)
            }
            let stillCopying = library.appendingPathComponent("\(UUID().uuidString).parola.tmp", isDirectory: true)
            try FileManager.default.createDirectory(at: stillCopying, withIntermediateDirectories: true)
            let copying = try makeTakeWAV("still-copying", seconds: 1.4)
            try FileManager.default.moveItem(at: copying, to: stillCopying.appendingPathComponent("audio.wav"))
            try FileManager.default.setAttributes([.modificationDate: hourAgo], ofItemAtPath: stillCopying.path)

            let alreadySaved = library.appendingPathComponent("\(UUID().uuidString).parola.tmp", isDirectory: true)
            try FileManager.default.createDirectory(at: alreadySaved, withIntermediateDirectories: true)
            let savedTake = try makeTakeWAV("saved-elsewhere", seconds: 1.3)
            defer { try? FileManager.default.removeItem(at: savedTake) }
            _ = try await LibraryStore(libraryURL: library, extraIndexer: nil).add(
                transcript: AppModel.untranscribedTranscript(of: savedTake, language: nil), audioSource: savedTake
            )
            try FileManager.default.copyItem(at: savedTake, to: alreadySaved.appendingPathComponent("audio.wav"))
            try FileManager.default.setAttributes([.modificationDate: hourAgo], ofItemAtPath: alreadySaved.path)
            try FileManager.default.setAttributes(
                [.modificationDate: hourAgo], ofItemAtPath: alreadySaved.appendingPathComponent("audio.wav").path
            )

            let model = makeModel(libraryURL: library)
            await model.inflightSweep?.value

            let listed = await model.library.list()
            #expect(listed.count == 3, "the two cut-off saves, and the take that was already there: no twin of it")
            #expect(!FileManager.default.fileExists(atPath: alreadySaved.path))
            let notes = try #require(listed.first { $0.title == "Meeting notes" })
            #expect(try await model.library.load(notes.id).document.transcript.text == "almost saved")
            let recovered = try #require(listed.first { $0.title.hasSuffix("(recovered)") })
            #expect(recovered.manifest.originalAudioName.isEmpty == false)
            #expect(!FileManager.default.fileExists(atPath: audioOnly.path))
            #expect(!FileManager.default.fileExists(atPath: complete.path))
            #expect(FileManager.default.fileExists(atPath: stillCopying.path), "an old folder with a file written just now is still in use")
        }

        @Test("the heartbeat marks only the working files in use as fresh")
        func heartbeatTouchesFilesInUse() throws {
            let library = makeTempLibraryURL("heartbeat")
            let inflight = library.appendingPathComponent("inflight", isDirectory: true)
            try FileManager.default.createDirectory(at: inflight, withIntermediateDirectories: true)
            let model = makeModel(libraryURL: library)
            let inUse = try makeTakeWAV("heartbeat-used", in: inflight, prefix: "parola-mic")
            let idle = try makeTakeWAV("heartbeat-idle", in: inflight, prefix: "parola-mic")
            let hourAgo = Date().addingTimeInterval(-3_600)
            for file in [inUse, idle] {
                try FileManager.default.setAttributes([.modificationDate: hourAgo], ofItemAtPath: file.path)
            }
            model.liveRecordingAudioURL = inUse

            model.touchTakeFilesInUse()

            func modified(_ file: URL) throws -> Date {
                try #require(try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            }
            #expect(try modified(inUse) > Date().addingTimeInterval(-60))
            #expect(try modified(idle) < Date().addingTimeInterval(-3_000))
        }

        @Test("dictation throws away only its own scratch, never a file with another name")
        func dictationDiscardsOnlyItsScratch() throws {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-scratch-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let own = folder.appendingPathComponent("\(RecordingScratch.dictationPrefix)-\(UUID().uuidString).wav")
            let fixture = folder.appendingPathComponent("fixture.wav")
            try Data("RIFF".utf8).write(to: own)
            try Data("RIFF".utf8).write(to: fixture)

            MicDictationRecorder.discardScratch(own)
            MicDictationRecorder.discardScratch(fixture)

            #expect(!FileManager.default.fileExists(atPath: own.path))
            #expect(FileManager.default.fileExists(atPath: fixture.path))
        }

        private func writeLegacyCheckpoint(_ checkpoint: RecoveryCheckpoint, library: URL) throws {
            try JSONEncoder().encode(checkpoint).write(to: library.appendingPathComponent("recovery.json"))
        }

        /// A take written minutes ago: a checkpoint with no owner treats anything newer as still recording.
        private func settledTake(_ label: String, in folder: URL) throws -> URL {
            let take = try makeTakeWAV(label, in: folder, prefix: "parola-mic")
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-300)], ofItemAtPath: take.path)
            return take
        }

        @Test("a second instance on the same library leaves a running instance's take alone: no offer, no sweep, no save")
        func secondInstanceLeavesALiveTakeAlone() async throws {
            let library = makeTempLibraryURL("two-instances")
            let inflight = library.appendingPathComponent("inflight", isDirectory: true)
            try FileManager.default.createDirectory(at: inflight, withIntermediateDirectories: true)
            let first = makeModel(libraryURL: library)
            let take = try makeTakeWAV("recording-elsewhere", seconds: 1, in: inflight, prefix: "parola-mic")
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3_600)], ofItemAtPath: take.path)
            first.beginRecordingRecovery()
            first.liveRecordingAudioURL = take
            first.writeRecordingCheckpoint()
            await first.pendingRecoveryWrite?.value
            let checkpoint = try #require(first.activeRecoveryFileURL)

            let second = makeModel(libraryURL: library)
            await second.inflightSweep?.value

            #expect(second.pendingRecovery == nil, "a live instance's take is not offered")
            #expect(FileManager.default.fileExists(atPath: checkpoint.path))
            #expect(FileManager.default.fileExists(atPath: take.path), "nor swept, though an hour quiet")
            #expect(await second.library.list().isEmpty)

            // The first instance goes away without ending its take, as a crash would.
            first.recoveryOwner = nil
            let third = makeModel(libraryURL: library)
            #expect(third.pendingRecovery?.audioURL == take, "once its instance is gone, the take is offered")
        }

        @Test("a checkpoint from a build before owners waits a launch while its take was written in the last two minutes")
        func ownerlessCheckpointWaitsForARecentTake() throws {
            let library = makeTempLibraryURL("ownerless-recent")
            let inflight = library.appendingPathComponent("inflight", isDirectory: true)
            try FileManager.default.createDirectory(at: inflight, withIntermediateDirectories: true)
            let take = try makeTakeWAV("old-build", in: inflight, prefix: "parola-mic")
            try writeLegacyCheckpoint(
                RecoveryCheckpoint(kind: .recording, startedAt: Date(), modelName: "m", audioURL: take), library: library
            )

            let model = makeModel(libraryURL: library)

            #expect(model.pendingRecovery == nil)
            #expect(FileManager.default.fileExists(atPath: model.legacyRecoveryFileURL.path), "left where it is, untouched")
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-300)], ofItemAtPath: take.path)
            model.recoveryOwner = nil
            #expect(makeModel(libraryURL: library).pendingRecovery?.audioURL == take)
        }

        @Test("Not Now keeps a take that was transcribing when Parola quit, untranscribed, and the offer names it by its title")
        func notNowKeepsATranscribingTake() async throws {
            let library = makeTempLibraryURL("not-now-take")
            let inflight = library.appendingPathComponent("inflight", isDirectory: true)
            try FileManager.default.createDirectory(at: inflight, withIntermediateDirectories: true)
            let take = try settledTake("not-now", in: inflight)
            try writeLegacyCheckpoint(RecoveryCheckpoint(
                kind: .fileTranscription, startedAt: Date(), modelName: "m",
                sourceURL: take, title: "Recording 29 Sep 2026", source: .systemAudio
            ), library: library)
            let model = makeModel(libraryURL: library)
            let offer = try #require(model.pendingRecovery)
            #expect(offer.isTake)
            #expect(offer.sourceName == "Recording 29 Sep 2026", "the prompt names the take, not its working file")

            model.declinePendingRecovery()

            let saved = try #require(await entries(model, count: 1).first)
            #expect(saved.title == "Recording 29 Sep 2026 (not transcribed)")
            #expect(saved.manifest.originalAudioName.isEmpty == false)
            #expect(saved.manifest.source == .systemAudio)
            #expect(try await model.library.load(saved.id).document.transcript.modelName.isEmpty)
            #expect(await waitUntil { model.recoveryCheckpointFiles.isEmpty }, "the checkpoint goes once the entry holds the take")
            #expect(model.phase == .idle, "a take kept for later doesn't open")
        }

        @Test("a meeting's checkpoint keeps it a meeting, whether it is restored or kept for later")
        func checkpointKeepsTheCategory() async throws {
            let library = makeTempLibraryURL("checkpoint-category")
            try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
            let segments = [TranscriptSegment(id: 0, start: 0, end: 1, text: "the agenda")]
            try writeLegacyCheckpoint(RecoveryCheckpoint(
                kind: .recording, startedAt: Date(), modelName: "m", segments: segments, source: .systemAudio, category: .meeting
            ), library: library)
            let model = makeModel(libraryURL: library)
            #expect(model.pendingRecovery?.category == .meeting)

            model.declinePendingRecovery()

            let kept = try #require(await entries(model, count: 1).first)
            #expect(kept.category == .meeting)
            #expect(kept.title.hasPrefix("Meeting "))

            let transcribing = makeModel()
            transcribing.beginFileTranscribeRecovery(
                sourceURL: URL(fileURLWithPath: "/tmp/parola-meeting.wav"), title: "Meeting 1", source: .systemAudio, category: .meeting
            )
            await transcribing.pendingRecoveryWrite?.value
            let written = try JSONDecoder().decode(
                RecoveryCheckpoint.self, from: try Data(contentsOf: try #require(transcribing.activeRecoveryFileURL))
            )
            #expect(written.category == .meeting, "a take transcribing at a crash comes back as what it was")
            transcribing.endActiveRecovery()
        }

        @Test("Restore waits while a take records: the offer stays and says why, and works once the take ends")
        func restoreWaitsForTheTakeInProgress() async throws {
            let library = makeTempLibraryURL("restore-during-take")
            try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
            let segments = [TranscriptSegment(id: 0, start: 0, end: 1, text: "from before the crash")]
            try writeLegacyCheckpoint(
                RecoveryCheckpoint(kind: .recording, startedAt: Date(), modelName: "m", segments: segments), library: library
            )
            let fixture = try makeTakeWAV("take-in-progress")
            defer { try? FileManager.default.removeItem(at: fixture) }
            try await withMocksCleared(.audioSource) {
                await MockAudioSourceRegistry.shared.install(kind: .mic, fixtureURL: fixture)
                let model = makeModel(libraryURL: library)
                model.useStreaming = false
                #expect(model.pendingRecovery != nil)
                model.startRecording(source: .microphone)
                await waitUntil { model.liveSource != nil }

                model.acceptPendingRecovery()

                #expect(model.pendingRecovery != nil, "the offer waits")
                #expect(model.phase == .recording(source: .microphone))
                #expect(model.exportNotice?.message == "Finish the recording first. Parola offers the recovered one again when it ends.")

                model.cancelCurrentWork()
                await waitUntil { !model.recordingActive }
                model.acceptPendingRecovery()
                #expect(model.pendingRecovery == nil)
                #expect(await waitUntil { model.transcript?.segments == segments })
            }
        }

        @Test("a take ends its own checkpoint, never a run that started meanwhile", .timeLimit(.minutes(1)))
        func takeEndsOnlyItsOwnCheckpoint() async throws {
            try await withMocksCleared([.audioSource, .streaming]) {
                await MockAudioSourceRegistry.shared.clear()
                let model = makeModel()
                await startStreamingTake(
                    model, segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "its own words")], delayMs: 300
                )
                await waitUntil { model.recordingStartedAt != nil }
                let recovery = try #require(model.activeTake?.recovery)
                model.liveRecordingAudioURL = URL(fileURLWithPath: "/tmp/parola-streamed-take.wav")
                model.writeRecordingCheckpoint()
                await model.pendingRecoveryWrite?.value
                let takeCheckpoint = model.recoveryFileURL(for: try #require(model.recoveryFileIDs[recovery]))
                #expect(FileManager.default.fileExists(atPath: takeCheckpoint.path))
                let other = model.beginFileTranscribeRecovery(sourceURL: URL(fileURLWithPath: "/tmp/parola-other-run.wav"))
                await model.pendingRecoveryWrite?.value
                let otherCheckpoint = try #require(model.activeRecoveryFileURL)

                model.stopRecordingAndTranscribe()

                _ = await entries(model, count: 1)
                #expect(await waitUntil { !FileManager.default.fileExists(atPath: takeCheckpoint.path) })
                #expect(FileManager.default.fileExists(atPath: otherCheckpoint.path), "the other run's checkpoint is its own to end")
                model.endRecovery(other)
            }
        }

        @Test("a checkpoint whose take already reached the library adds no twin, kept or restored, and two checkpoints for one take come down to one")
        func recoveredTakesNeverTwin() async throws {
            let library = makeTempLibraryURL("no-twins")
            let inflight = library.appendingPathComponent("inflight", isDirectory: true)
            try FileManager.default.createDirectory(at: inflight, withIntermediateDirectories: true)
            let take = try settledTake("saved-before-the-crash", in: inflight)
            let seed = LibraryStore(libraryURL: library, extraIndexer: nil)
            let existing = try await seed.add(
                transcript: AppModel.untranscribedTranscript(of: take, language: nil), audioSource: take, title: "Recording 1 (not transcribed)"
            )
            let folder = library.appendingPathComponent("recovery", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let capture = RecoveryCheckpoint(kind: .recording, startedAt: Date().addingTimeInterval(-60), modelName: "m", audioURL: take)
            let transcribing = RecoveryCheckpoint(
                kind: .fileTranscription, startedAt: Date(), modelName: "m", sourceURL: take, title: "Recording 1"
            )
            for checkpoint in [capture, transcribing] {
                try JSONEncoder().encode(checkpoint).write(to: folder.appendingPathComponent("\(checkpoint.id.uuidString).json"))
            }

            let model = makeModel(libraryURL: library)
            #expect(model.pendingRecovery?.id == transcribing.id)
            #expect(model.recoveryCheckpointFiles.count == 1, "the capture's checkpoint for the same file is dropped")

            model.declinePendingRecovery()

            #expect(await waitUntil { model.recoveryCheckpointFiles.isEmpty })
            await settle()
            let listed = await model.library.list()
            #expect(listed.map(\.id) == [existing.id], "Not Now adds no twin of a take already in the library")
        }

        @Test("Transcribe on a take the library already holds opens that entry and transcribes it there")
        func acceptOpensTheSavedTake() async throws {
            let library = makeTempLibraryURL("accept-saved")
            let inflight = library.appendingPathComponent("inflight", isDirectory: true)
            try FileManager.default.createDirectory(at: inflight, withIntermediateDirectories: true)
            let take = try settledTake("saved-then-crashed", in: inflight)
            let seed = LibraryStore(libraryURL: library, extraIndexer: nil)
            let existing = try await seed.add(
                transcript: AppModel.untranscribedTranscript(of: take, language: nil), audioSource: take, title: "Recording 2 (not transcribed)"
            )
            try writeLegacyCheckpoint(RecoveryCheckpoint(
                kind: .fileTranscription, startedAt: Date(), modelName: "m", sourceURL: take, title: "Recording 2"
            ), library: library)
            try await withMocksCleared(.transcriber) {
                await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "at last")]
                ))
                let model = makeModel(libraryURL: library)

                model.acceptPendingRecovery()

                #expect(await waitUntil { model.selectedEntryID == existing.id && model.transcript?.text == "at last" })
                #expect(await model.library.list().map(\.id) == [existing.id])
                #expect(await waitUntil { model.recoveryCheckpointFiles.isEmpty })
            }
        }

        @Test("only a confirmed Discard deletes a recovered take's audio")
        func discardDeletesTheTake() async throws {
            let library = makeTempLibraryURL("discard-take")
            let inflight = library.appendingPathComponent("inflight", isDirectory: true)
            try FileManager.default.createDirectory(at: inflight, withIntermediateDirectories: true)
            let take = try settledTake("discarded", in: inflight)
            try writeLegacyCheckpoint(
                RecoveryCheckpoint(kind: .recording, startedAt: Date(), modelName: "m", audioURL: take), library: library
            )
            let model = makeModel(libraryURL: library)
            #expect(model.pendingRecovery?.isTake == true)

            model.discardPendingRecovery()

            #expect(model.pendingRecovery == nil)
            #expect(!FileManager.default.fileExists(atPath: take.path))
            #expect(model.recoveryCheckpointFiles.isEmpty)
            await settle()
            #expect(await model.library.list().isEmpty)
        }

        @Test("Not Now on a file's offer leaves the file where it is and just drops the offer")
        func notNowDropsAFileOffer() async throws {
            let library = makeTempLibraryURL("not-now-file")
            try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
            let file = try makeTakeWAV("users-own")
            defer { try? FileManager.default.removeItem(at: file) }
            try writeLegacyCheckpoint(
                RecoveryCheckpoint(kind: .fileTranscription, startedAt: Date(), modelName: "m", sourceURL: file), library: library
            )
            let model = makeModel(libraryURL: library)
            let offer = try #require(model.pendingRecovery)
            #expect(!offer.isTake)
            #expect(offer.sourceName == file.lastPathComponent)

            model.declinePendingRecovery()

            #expect(model.recoveryCheckpointFiles.isEmpty)
            #expect(FileManager.default.fileExists(atPath: file.path))
            await settle()
            #expect(await model.library.list().isEmpty)
        }

        // MARK: - Quitting during a take        // MARK: - Quitting during a take

        @Test("quitting with no take in progress goes at once and asks nothing")
        func quitWithoutATakeAsksNothing() {
            let model = makeModel()
            let quit = QuitReply()
            let reply = AppDelegate.terminateReply(for: model, ask: { quit.asked = true; return .keepRecording }) { _ in }
            #expect(reply == .terminateNow)
            #expect(!quit.asked)
            #expect(AppDelegate.terminateReply(for: nil, ask: { .discard }) { _ in } == .terminateNow)
        }

        private func capturingTake(_ fixture: URL) async -> AppModel {
            await MockAudioSourceRegistry.shared.install(kind: .mic, fixtureURL: fixture)
            let model = makeModel()
            model.useStreaming = false
            model.startRecording(source: .microphone)
            await waitUntil { model.takeInProgress }
            return model
        }

        @Test("Keep Recording cancels the quit and leaves the take running")
        func keepRecordingCancelsTheQuit() async throws {
            let fixture = try makeTakeWAV("keep")
            defer { try? FileManager.default.removeItem(at: fixture) }
            try await withMocksCleared(.audioSource) {
                let model = await capturingTake(fixture)
                let quit = QuitReply()
                let reply = AppDelegate.terminateReply(for: model, ask: { .keepRecording }) { quit.value = $0 }
                #expect(reply == .terminateCancel)
                await settle()
                #expect(quit.value == nil)
                #expect(model.takeInProgress)
                model.cancelCurrentWork()
            }
        }

        @Test("Stop and Save puts a file take in the library, then lets the app quit; a second quit meanwhile is ignored")
        func stopAndSaveKeepsAFileTake() async throws {
            let fixture = try makeTakeWAV("save")
            defer { try? FileManager.default.removeItem(at: fixture) }
            try await withMocksCleared(.audioSource) {
                let model = await capturingTake(fixture)
                let quit = QuitReply()
                let reply = AppDelegate.terminateReply(for: model, ask: { .stopAndSave }) { quit.value = $0 }
                #expect(reply == .terminateLater)
                #expect(AppDelegate.terminateReply(for: model, ask: { .discard }) { _ in } == .terminateCancel)

                await waitUntil { quit.value != nil }
                #expect(quit.value == true)
                let listed = await model.library.list()
                #expect(listed.count == 1, "the take is saved before the app is told it may quit")
                #expect(listed.first?.title.hasSuffix("(not transcribed)") == true)
                #expect(listed.first?.manifest.originalAudioName.isEmpty == false)
                #expect(model.recoveryCheckpointFiles.isEmpty)
                #expect(!model.takeInProgress)
            }
        }

        @Test("Stop and Save keeps a live take's words and audio, then lets the app quit", .timeLimit(.minutes(1)))
        func stopAndSaveKeepsALiveTake() async throws {
            try await withMocksCleared([.audioSource, .streaming]) {
                await MockAudioSourceRegistry.shared.clear()
                let model = makeModel()
                await startStreamingTake(
                    model, segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "said before quitting")], delayMs: 300
                )
                await waitUntil { model.takeInProgress }
                let quit = QuitReply()

                let reply = AppDelegate.terminateReply(for: model, ask: { .stopAndSave }) { quit.value = $0 }
                #expect(reply == .terminateLater)

                await waitUntil { quit.value != nil }
                #expect(quit.value == true)
                #expect(model.savingTakesBeforeQuit, "the window said it was saving")
                let saved = try #require(await model.library.list().first)
                #expect(!saved.title.contains("("), "a live take keeps its words, so its title carries no note")
                let stored = try await model.library.load(saved.id).document.transcript
                #expect(stored.text.contains("said before quitting"))
            }
        }

        @Test("quitting while a take transcribes stops the run, saves the take untranscribed, then lets the app quit")
        func quitWhileATakeTranscribes() async throws {
            let wav = try makeTakeWAV("quit-transcribing")
            defer { try? FileManager.default.removeItem(at: wav) }
            try await withMocksCleared(.transcriber) {
                await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "never landed")],
                    gate: MockTranscriberGate()
                ))
                let model = makeModel()
                await transcribingTake(model, wav: wav)
                #expect(!model.takeInProgress)
                #expect(model.hasPendingTakeWork, "a take's transcription is work a quit waits for")
                let quit = QuitReply()

                let reply = AppDelegate.terminateReply(for: model, ask: { quit.asked = true; return .keepRecording }) { quit.value = $0 }

                #expect(reply == .terminateLater)
                #expect(!quit.asked, "nothing is capturing, so there is nothing to ask")
                await waitUntil { quit.value != nil }
                #expect(quit.value == true)
                let saved = await model.library.list()
                #expect(saved.count == 1, "the take is in the library before the app is told it may quit")
                #expect(saved.first?.title.hasSuffix("(not transcribed)") == true)
            }
        }

        @Test("a quit stops waiting once its limit passes on the model's clock, with a save still on its way")
        func quitWaitIsBounded() async throws {
            let wav = try makeTakeWAV("quit-limit")
            defer { try? FileManager.default.removeItem(at: wav) }
            try await withMocksCleared(.transcriber) {
                await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "never landed")],
                    gate: MockTranscriberGate()
                ))
                let model = makeModel(clock: InstantClock())
                await transcribingTake(model, wav: wav)

                await model.finishTakeWorkForQuit()

                #expect(model.hasPendingTakeWork, "the limit ended the wait, not the work")
                #expect(model.savingTakesBeforeQuit)
                await waitUntil { !model.hasPendingTakeWork }
                #expect(await model.library.list().count == 1, "the take still lands once the save finishes")
            }
        }

        @Test("Record does nothing while a quit is winding the takes down")
        func recordRefusedWhileQuitting() async {
            let model = makeModel()
            model.quitPending = true
            model.pendingRecordingCategory = .meeting

            model.startRecording(source: .microphone)

            await settle()
            #expect(model.activeTake == nil)
            #expect(!model.recordingActive)
            #expect(model.pendingRecordingCategory == .transcription, "the refused request's category is spent")
        }

        @Test("a count-in running when a quit begins never becomes a take")
        func countInEndsWithTheQuit() async throws {
            let fixture = try makeTakeWAV("count-in")
            defer { try? FileManager.default.removeItem(at: fixture) }
            try await withMocksCleared(.audioSource) {
                await MockAudioSourceRegistry.shared.install(kind: .mic, fixtureURL: fixture)
                let model = makeModel()
                model.useStreaming = false
                model.recordingCountInSeconds = 1
                model.startRecording(source: .microphone)
                #expect(model.recordingCountdown != nil)

                model.quitPending = true

                #expect(model.recordingCountdown == nil)
                await settle(for: .milliseconds(1_500))
                #expect(model.activeTake == nil)
                #expect(!model.recordingActive)
            }
        }

        @Test("Discard drops the take, then lets the app quit")
        func discardDropsTheTake() async throws {
            let fixture = try makeTakeWAV("discard")
            defer { try? FileManager.default.removeItem(at: fixture) }
            try await withMocksCleared(.audioSource) {
                let model = await capturingTake(fixture)
                let quit = QuitReply()
                let reply = AppDelegate.terminateReply(for: model, ask: { .discard }) { quit.value = $0 }
                #expect(reply == .terminateLater)

                await waitUntil { quit.value != nil }
                #expect(quit.value == true)
                #expect(!model.takeInProgress)
                #expect(model.phase == .idle)
                await settle()
                #expect(await model.library.list().isEmpty)
            }
        }

        // MARK: - Legibility

        @Test("white on the Stop fill clears 4.5:1 in both appearances")
        func stopFillIsLegible() {
            let fill = DS.Color.recordingFillTheme.appearanceVariants
            let white = RGBA(1, 1, 1)
            #expect(white.contrast(against: fill.light) >= RGBA.textContrastMinimum)
            #expect(white.contrast(against: fill.dark) >= RGBA.textContrastMinimum)
        }

        @Test("warning banners set near-black text on solid amber, at 7:1 or more")
        func warningBannerIsLegible() {
            let amber = ThemePalette.sharedNeutrals.warning.appearanceVariants
            let ink = DS.Color.warningBannerInkRGBA
            #expect(ink.contrast(against: amber.light) >= 7)
            #expect(ink.contrast(against: amber.dark) >= 7)
        }
    }
}
