import AppKit
import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

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

/// Whether a quit asked, and the reply it handed back once the take was wound down.
@MainActor
private final class QuitReply {
    var value: Bool?
    var asked = false
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
            let model = makeModel()
            model.liveSource = CutShortTake(url: wav)
            model.phase = .recording(source: .microphone)

            model.stopRecordingAndTranscribe()

            let saved = try #require(await entries(model, count: 1).first)
            #expect(saved.title.hasSuffix("(interrupted)"))
            #expect(saved.manifest.originalAudioName.isEmpty == false)
            #expect(FileManager.default.fileExists(atPath: wav.path), "the take's file is never deleted")
            await waitUntil {
                if case .failed(let message) = model.phase { return message.contains("saved to your library") }
                return false
            }
            #expect(model.failedTakeAudioURL == wav, "Retry transcribes what was kept")
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

        @Test("the sweep brings back a take that never reached the library and drops copies of saved ones")
        func sweepImportsOrphanedTakes() async throws {
            let library = makeTempLibraryURL("sweep-import")
            let inflight = library.appendingPathComponent("inflight", isDirectory: true)
            try FileManager.default.createDirectory(at: inflight, withIntermediateDirectories: true)
            let orphan = try makeTakeWAV("orphan", seconds: 1, in: inflight, prefix: "parola-mic")
            let savedCopy = try makeTakeWAV("saved", seconds: 1.1, in: inflight, prefix: "parola-system")
            let fresh = try makeTakeWAV("fresh", seconds: 1.2, in: inflight, prefix: "parola-recording")
            let seed = LibraryStore(libraryURL: library, extraIndexer: nil)
            _ = try await seed.add(
                transcript: AppModel.untranscribedTranscript(of: savedCopy, language: nil),
                audioSource: savedCopy
            )
            let old = Date().addingTimeInterval(-3_600)
            for file in [orphan, savedCopy] {
                try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.path)
            }

            let model = makeModel(libraryURL: library)
            await model.inflightSweep?.value

            let listed = await model.library.list()
            #expect(listed.count == 2, "the saved take isn't imported a second time")
            let recovered = try #require(listed.first { $0.title.hasSuffix("(recovered)") })
            #expect(try await model.library.load(recovered.id).document.transcript.modelName.isEmpty)
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

        @Test("Not Now keeps a take that was transcribing when Parola quit, untranscribed, and the offer names it by its title")
        func notNowKeepsATranscribingTake() async throws {
            let library = makeTempLibraryURL("not-now-take")
            let inflight = library.appendingPathComponent("inflight", isDirectory: true)
            try FileManager.default.createDirectory(at: inflight, withIntermediateDirectories: true)
            let take = try makeTakeWAV("not-now", in: inflight, prefix: "parola-mic")
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

        @Test("only a confirmed Discard deletes a recovered take's audio")
        func discardDeletesTheTake() async throws {
            let library = makeTempLibraryURL("discard-take")
            let inflight = library.appendingPathComponent("inflight", isDirectory: true)
            try FileManager.default.createDirectory(at: inflight, withIntermediateDirectories: true)
            let take = try makeTakeWAV("discarded", in: inflight, prefix: "parola-mic")
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
