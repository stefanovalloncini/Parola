import AVFoundation
import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Intent actions")
struct IntentActionsTests {

    private func makeModel() -> AppModel {
        AppModel(
            skipBootstrap: true,
            defaults: temporaryDefaults(),
            libraryURL: makeTempLibraryURL("intent-actions")
        )
    }

    @Test("transcribe-file intent throws while recording")
    func transcribeThrowsWhileRecording() async {
        let model = makeModel()
        model.installTestTake(source: .microphone)
        await #expect(throws: IntentActionError.recordingInProgress) {
            _ = try await model.transcribeFileFromIntent(URL(fileURLWithPath: "/tmp/a.wav"))
        }
    }

    @Test("transcribe-file intent throws while a batch is running")
    func transcribeThrowsWhileBatchRunning() async throws {
        let model = makeModel()
        model.startBatch(urls: [URL(fileURLWithPath: "/tmp/a.wav")])
        await model.handleBatchEvent(.started(jobID: model.batchJobs[0].id))
        await #expect(throws: IntentActionError.batchInProgress) {
            _ = try await model.transcribeFileFromIntent(URL(fileURLWithPath: "/tmp/b.wav"))
        }
    }

    @Test("transcribe-file intent rejects subtitle and project files")
    func transcribeRejectsNonMedia() async {
        let model = makeModel()
        await #expect(throws: IntentActionError.self) {
            _ = try await model.transcribeFileFromIntent(URL(fileURLWithPath: "/tmp/subs.srt"))
        }
        await #expect(throws: IntentActionError.self) {
            _ = try await model.transcribeFileFromIntent(URL(fileURLWithPath: "/tmp/doc.parola"))
        }
    }

    private func makeWAV(seconds: Double) throws -> URL {
        let sampleRate = 16_000, channels = 1, bytesPerSample = 2
        let dataBytes = Int(Double(sampleRate) * seconds) * channels * bytesPerSample
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
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-intent-open-\(UUID().uuidString).wav")
        try data.write(to: url)
        return url
    }

    /// Manifests keep whole seconds, so the older entry is dated back an hour rather than added first.
    private func seedTwoEntries(in model: AppModel) async throws -> (older: LibraryEntry, newest: LibraryEntry) {
        func add(_ text: String, seconds: Double) async throws -> LibraryEntry {
            let audio = try makeWAV(seconds: seconds)
            defer { try? FileManager.default.removeItem(at: audio) }
            return try await model.library.add(
                transcript: Transcript(
                    segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: text)],
                    language: "en",
                    modelName: "stub"
                ),
                audioSource: audio
            )
        }
        let older = try await add("the older take", seconds: 0.3)
        try ParolaDocument.updateManifest(at: older.bundleURL) { $0.createdAt = Date(timeIntervalSinceNow: -3600) }
        let newest = try await add("the newest take", seconds: 0.4)
        return (older, newest)
    }

    private func storedText(_ entry: LibraryEntry) throws -> String {
        try ParolaDocument.read(at: entry.bundleURL).transcript.text
    }

    @Test("Open Last Transcript opens the newest entry, and the next edit lands in it", .timeLimit(.minutes(1)))
    func openLatestOpensTheEntry() async throws {
        let model = makeModel()
        let (older, newest) = try await seedTwoEntries(in: model)
        try await model.openEntry(older.id)
        let newestAudio = try await model.library.load(newest.id).document.audioURL

        let text = try await model.openLatestFromIntent()

        #expect(text == "the newest take")
        #expect(model.selectedEntryID == newest.id)
        #expect(model.transcript?.text == "the newest take")
        #expect(model.sourceFileURL == newestAudio)

        model.editSegment(id: 0, newText: "edited after the shortcut")
        await model.flushPendingTranscriptSave()

        #expect(try storedText(newest) == "edited after the shortcut")
        #expect(try storedText(older) == "the older take")
    }

    @Test("Open Last Transcript opens the newest entry during a take, and the take keeps recording", .timeLimit(.minutes(1)))
    func openLatestDuringATake() async throws {
        let model = makeModel()
        let (_, newest) = try await seedTwoEntries(in: model)
        model.installTestTake(source: .microphone)

        let text = try await model.openLatestFromIntent()

        #expect(text == "the newest take")
        #expect(model.selectedEntryID == newest.id)
        #expect(model.recording?.isCapturing == true)
    }

    @Test("Summarize Last Transcript opens and summarises the newest entry during a take", .timeLimit(.minutes(1)))
    func summarizeLatestDuringATake() async throws {
        let model = AppModel(
            skipBootstrap: true,
            defaults: temporaryDefaults(),
            libraryURL: makeTempLibraryURL("intent-summarize-recording"),
            features: Set(ParolaFeature.allCases)
        )
        model.summariseOperation = { _, _ in Summary(text: "recap") }
        let (_, newest) = try await seedTwoEntries(in: model)
        model.installTestTake(source: .microphone)

        model.summarizeLatestEntry()

        let summarized = await waitUntil { model.selectedEntryID == newest.id && model.transcript?.summary?.text == "recap" }
        #expect(summarized)
        #expect(model.recording?.isCapturing == true)
    }

    @Test("Open Last Transcript on an empty library says so")
    func openLatestOnAnEmptyLibrary() async {
        let model = makeModel()
        await #expect(throws: IntentActionError.libraryEmpty) {
            _ = try await model.openLatestFromIntent()
        }
    }

    @Test("Summarize Last Transcript opens the entry with its own audio before summarising", .timeLimit(.minutes(1)))
    func summarizeLatestOpensTheEntry() async throws {
        let model = AppModel(
            skipBootstrap: true,
            defaults: temporaryDefaults(),
            libraryURL: makeTempLibraryURL("intent-summarize"),
            features: Set(ParolaFeature.allCases)
        )
        model.summariseOperation = { _, _ in Summary(text: "recap") }
        let (older, newest) = try await seedTwoEntries(in: model)
        try await model.openEntry(older.id)
        let newestAudio = try await model.library.load(newest.id).document.audioURL

        model.summarizeLatestEntry()

        let summarized = await waitUntil { model.selectedEntryID == newest.id && model.transcript?.summary?.text == "recap" }
        #expect(summarized)
        #expect(model.transcript?.text == "the newest take")
        #expect(model.sourceFileURL == newestAudio)
        #expect((model.player?.currentItem?.asset as? AVURLAsset)?.url == newestAudio)
    }

    @Test("stop-recording intent throws when nothing is recording")
    func stopThrowsWhenIdle() async {
        let model = makeModel()
        await #expect(throws: IntentActionError.notRecording) {
            _ = try await model.stopRecordingFromIntent()
        }
    }

    @Test("stop-recording intent throws when the take has no capture behind it")
    func stopThrowsOnATakeWithoutACapture() async {
        let model = makeModel()
        model.installTestTake(source: .microphone)
        await #expect(throws: IntentActionError.notRecording) {
            _ = try await model.stopRecordingFromIntent()
        }
    }

    @Test("a recording outcome waiter gets the transcript text when streaming finishes", .timeLimit(.minutes(1)))
    func waiterReceivesStreamingFinish() async throws {
        let model = makeModel()
        let waiter = Task { try await model.awaitRecordingOutcome() }
        while model.recordingOutcomeWaiters.isEmpty { await Task.yield() }

        let final = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "done words")],
            language: "en",
            modelName: "mock"
        )
        await model.handleStreamingEvent(.finished(final))

        let text = try await waiter.value
        #expect(text == "done words")
    }

    @Test("a streaming failure rejects pending waiters with the failure message", .timeLimit(.minutes(1)))
    func waiterReceivesStreamingFailure() async throws {
        let model = makeModel()
        let waiter = Task { try await model.awaitRecordingOutcome() }
        while model.recordingOutcomeWaiters.isEmpty { await Task.yield() }

        await model.handleStreamingEvent(.failed("mic died"))

        await #expect(throws: IntentActionError.failed("mic died")) {
            _ = try await waiter.value
        }
    }

    @Test("cancelling current work rejects pending waiters", .timeLimit(.minutes(1)))
    func waiterRejectedOnCancel() async throws {
        let model = makeModel()
        let waiter = Task { try await model.awaitRecordingOutcome() }
        while model.recordingOutcomeWaiters.isEmpty { await Task.yield() }

        model.cancelCurrentWork()

        await #expect(throws: IntentActionError.cancelled) {
            _ = try await waiter.value
        }
    }

    @Test("registerIntentPerformers installs every hook")
    func registrationInstallsHooks() async throws {
        defer {
            IntentPerformers.stopRecording = nil
            IntentPerformers.transcribeFile = nil
            IntentPerformers.openLatest = nil
        }
        let model = makeModel()
        model.registerIntentPerformers()

        #expect(IntentPerformers.stopRecording != nil)
        #expect(IntentPerformers.transcribeFile != nil)
        #expect(IntentPerformers.openLatest != nil)
        await #expect(throws: IntentActionError.notRecording) {
            _ = try await IntentPerformers.stopRecording?()
        }
    }
}

extension TranscriberMockSuites {
    @MainActor
    @Suite("Transcribe File intent", .serialized)
    struct TranscribeFileIntentTests {

        private func makeModel(_ label: String) -> AppModel {
            AppModel(bootstrap: AppBootstrap(
                mode: .test,
                library: makeTempLibraryURL("intent-\(label)"),
                defaultsOverride: temporaryDefaults(),
                sideEffects: [],
                filePicker: TestFilePicker(),
                clock: ContinuousClock()
            ))
        }

        private func makeWAV(_ label: String) throws -> URL {
            let sampleRate = 16_000, channels = 1, bytesPerSample = 2
            let dataBytes = Int(Double(sampleRate) * 0.3) * channels * bytesPerSample
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
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("parola-intent-\(label)-\(UUID().uuidString).wav")
            try data.write(to: url)
            return url
        }

        private func installMock() async {
            await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "words from a shortcut")], delayMs: 50
            ))
        }

        private func seedLibrary(_ model: AppModel, with audio: URL) async throws -> LibraryEntry {
            try await model.library.add(
                transcript: Transcript(
                    segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "already here")],
                    language: "en",
                    modelName: "openai_whisper-tiny"
                ),
                audioSource: audio,
                title: "Board meeting"
            )
        }

        @Test("returns the run's text once its entry and media are in the library", .timeLimit(.minutes(1)))
        func returnsTextAfterTheEntryLands() async throws {
            try await withMocksCleared(.transcriber) {
                await installMock()
                let model = makeModel("happy")
                let wav = try makeWAV("happy")
                defer { try? FileManager.default.removeItem(at: wav) }

                let text = try await model.transcribeFileFromIntent(wav)

                #expect(text.localizedCaseInsensitiveContains("words from a shortcut"))
                let entries = await model.library.list()
                try #require(entries.count == 1, "the intent returned before its entry reached the library")
                let stored = try await model.library.load(entries[0].id)
                #expect(stored.document.transcript.text == text)
                let audio = try #require(stored.document.audioURL)
                #expect(FileManager.default.fileExists(atPath: audio.path))
                #expect(model.fileTranscribeTask == nil)
            }
        }

        @Test("a Shortcut whose run fails after the user went to another page hears the run's own error", .timeLimit(.minutes(1)))
        func failureOutOfSightReachesTheShortcut() async throws {
            try await withMocksCleared(.transcriber) {
                let gate = MockTranscriberGate()
                defer { Task { await gate.open() } }
                await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                    failure: MockTranscriberFailure(code: .transcriptionFailed, message: "boom"), gate: gate
                ))
                let model = makeModel("fails-out-of-sight")
                let wav = try makeWAV("fails")
                defer { try? FileManager.default.removeItem(at: wav) }

                let shortcut = Task { try await model.transcribeFileFromIntent(wav) }
                let started = await waitUntil { model.fileTranscribeTask != nil }
                try #require(started, "the Shortcut never started a run")
                model.openStatistics()
                await gate.open()

                do {
                    _ = try await shortcut.value
                    Issue.record("the Shortcut heard a failed run succeed")
                } catch let error as IntentActionError {
                    #expect(error == .failed("Transcription failed: boom"))
                }
                #expect(model.exportNotice?.message == "Couldn't transcribe \(wav.lastPathComponent). boom", "the failure went unshown")
            }
        }

        @Test("a file the library holds answers with the stored text and opens the entry", .timeLimit(.minutes(1)),
              arguments: [DuplicateImportPolicy.alwaysAsk, .openExisting])
        func duplicateOpensTheStoredEntry(policy: DuplicateImportPolicy) async throws {
            try await withMocksCleared(.transcriber) {
                await installMock()
                let model = makeModel("dup-\(policy.rawValue)")
                model.duplicateImportPolicy = policy
                let wav = try makeWAV("dup")
                defer { try? FileManager.default.removeItem(at: wav) }
                let existing = try await seedLibrary(model, with: wav)

                let text = try await model.transcribeFileFromIntent(wav)

                #expect(text == "already here")
                #expect(model.selectedEntryID == existing.id)
                #expect(model.transcript?.text == "already here")
                #expect(model.duplicateImport == nil)
                #expect(model.fileTranscribeTask == nil)
                #expect(await model.library.list().count == 1)
            }
        }

        @Test("Transcribe it again runs a library file once more", .timeLimit(.minutes(1)))
        func transcribeAgainRunsTheDuplicate() async throws {
            try await withMocksCleared(.transcriber) {
                await installMock()
                let model = makeModel("dup-again")
                model.duplicateImportPolicy = .transcribeAgain
                let wav = try makeWAV("again")
                defer { try? FileManager.default.removeItem(at: wav) }
                _ = try await seedLibrary(model, with: wav)

                let text = try await model.transcribeFileFromIntent(wav)

                #expect(text.localizedCaseInsensitiveContains("words from a shortcut"))
                #expect(await model.library.list().count == 2)
            }
        }
    }
}
