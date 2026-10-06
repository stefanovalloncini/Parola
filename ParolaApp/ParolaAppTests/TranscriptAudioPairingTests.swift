import Foundation
import Testing
import AVFoundation
import os
@testable import Parola
import ParolaCore
import ParolaTestSupport

private let fixtureSerial = OSAllocatedUnfairLock(initialState: 0)

/// A length of its own per fixture: equal-length silence hashes alike, so the duplicate check drops the run.
private func makeSilentWAV(label: String) throws -> URL {
    let serial = fixtureSerial.withLock { count -> Int in
        count += 1
        return count
    }
    let sampleRate = 16_000, channels = 1, bytesPerSample = 2
    let frames = Int(Double(sampleRate) * 0.3) + serial
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
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("parola-pairing-\(label)-\(UUID().uuidString).wav")
    try data.write(to: url)
    return url
}

extension TranscriberMockSuites {
    @MainActor
    @Suite("Transcript audio pairing", .serialized)
    struct TranscriptAudioPairingTests {

        private func makeModel(picker: TestFilePicker = TestFilePicker()) -> AppModel {
            let bootstrap = AppBootstrap(
                mode: .test,
                library: makeTempLibraryURL("pairing"),
                defaultsOverride: temporaryDefaults(),
                sideEffects: [],
                filePicker: picker,
                clock: ContinuousClock()
            )
            return AppModel(bootstrap: bootstrap)
        }

        /// A wall-clock deadline: 15 ms sleeps drift under load, so a tally bounds the checks, not the wait.
        private func waitUntil(timeout: Duration = .seconds(30), _ condition: @MainActor () -> Bool) async -> Bool {
            let deadline = ContinuousClock.now + timeout
            while ContinuousClock.now < deadline {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(15))
            }
            return condition()
        }

        /// A run that lands empty resolved no mock: a stray teardown cleared the registry before it looked.
        private let mockWentMissing: Comment = "the run landed without the mock's words"

        private func playerURL(_ model: AppModel) -> URL? {
            (model.player?.currentItem?.asset as? AVURLAsset)?.url
        }

        private func heldMock(_ gate: MockTranscriberGate) -> MockTranscriberResponse {
            MockTranscriberResponse(
                segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "the run's own words")],
                gate: gate
            )
        }

        /// Opens a library entry with its own audio while the run under test is still transcribing.
        private func openOtherEntry(in model: AppModel) async throws -> (id: LibraryEntry.ID, audio: URL) {
            let audio = try makeSilentWAV(label: "entry")
            defer { try? FileManager.default.removeItem(at: audio) }
            let seed = LibraryStore(libraryURL: model.library.libraryURL, extraIndexer: nil)
            let entry = try await seed.add(
                transcript: Transcript(
                    segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "an older take")],
                    language: "en",
                    modelName: "stub"
                ),
                audioSource: audio,
                category: .transcription
            )
            model.loadEntry(entry.id)
            let opened = await waitUntil { model.selectedEntryID == entry.id && model.player != nil }
            #expect(opened, "the entry should be open before the transcription lands")
            return (entry.id, try #require(model.sourceFileURL))
        }

        /// The run saved out of sight: its entry, which holds the run's own words and audio, and the toast that says so.
        private func savedOutOfSight(_ model: AppModel, besides other: LibraryEntry.ID? = nil) async throws -> LibraryEntry {
            let saved = await model.library.list().filter { $0.id != other }
            let run = try #require(saved.first)
            let stored = try await model.library.load(run.id).document
            #expect(stored.transcript.text.contains("own words"), mockWentMissing)
            #expect(
                stored.audioURL?.deletingLastPathComponent().lastPathComponent == run.bundleURL.lastPathComponent,
                "the run keeps its own audio"
            )
            #expect(model.arrivalNotice?.state == .saved(run.id))
            let title = model.arrivalNotice?.savedTitle()
            #expect(title == "Saved “\(LibraryEntryDisplay.title(for: run))” to Transcriptions")
            return run
        }

        @Test("a file run that finishes after the user opened an entry is saved with its own audio, and the entry stays open")
        func fileRunLeavesTheOpenedEntry() async throws {
            try await withMocksCleared(.transcriber) {
                let gate = MockTranscriberGate()
                defer { Task { await gate.open() } }
                await MockTranscriberRegistry.shared.install(engineID: nil, response: heldMock(gate))

                let model = makeModel()
                let wav = try makeSilentWAV(label: "file")
                defer { try? FileManager.default.removeItem(at: wav) }

                model.transcribe(fileURL: wav)
                await model.awaitDuplicateCheck()
                try #require(model.fileTranscribeTask != nil, "the import never started a run")
                let other = try await openOtherEntry(in: model)
                #expect(model.sourceFileURL == other.audio)
                try #require(model.transcript?.text.contains("own words") != true, "the run must still be in flight")

                await gate.open()
                let landed = await waitUntil { model.arrivalNotice?.origin == .run }
                #expect(landed, "the run never landed")
                #expect(model.selectedEntryID == other.id, "the run took the entry the user opened")
                #expect(model.transcript?.text.contains("own words") != true, "the run's words replaced the entry's")
                #expect(model.sourceFileURL == other.audio, "the entry lost its own audio to the run")
                #expect(playerURL(model) == other.audio, "the entry would play the run's audio")
                #expect(model.phase == .ready)
                _ = try await savedOutOfSight(model, besides: other.id)
            }
        }

        @Test("a file run whose page stays up lands on it and opens there, with no toast")
        func fileRunLandsOnItsPage() async throws {
            try await withMocksCleared(.transcriber) {
                let gate = MockTranscriberGate()
                defer { Task { await gate.open() } }
                await MockTranscriberRegistry.shared.install(engineID: nil, response: heldMock(gate))

                let model = makeModel()
                let wav = try makeSilentWAV(label: "stayed")
                defer { try? FileManager.default.removeItem(at: wav) }

                model.transcribe(fileURL: wav)
                await model.awaitDuplicateCheck()
                try #require(model.fileTranscribeTask != nil, "the import never started a run")

                await gate.open()
                let selected = await waitUntil { model.selectedEntryID != nil }
                #expect(selected, "the run never opened as its entry")
                #expect(model.route == .transcript)
                #expect(model.phase == .ready)
                #expect(model.transcript?.text.contains("own words") == true, mockWentMissing)
                #expect(model.sourceFileURL == wav)
                #expect(playerURL(model) == wav)
                #expect(model.arrivalNotice == nil, "a run on its own page needs no toast")
            }
        }

        @Test("a file run that finishes while another page shows is saved out of sight, and the page stays")
        func fileRunLeavesAnotherPage() async throws {
            try await withMocksCleared(.transcriber) {
                let gate = MockTranscriberGate()
                defer { Task { await gate.open() } }
                await MockTranscriberRegistry.shared.install(engineID: nil, response: heldMock(gate))

                let model = makeModel()
                let wav = try makeSilentWAV(label: "statistics")
                defer { try? FileManager.default.removeItem(at: wav) }

                model.transcribe(fileURL: wav)
                await model.awaitDuplicateCheck()
                try #require(model.fileTranscribeTask != nil, "the import never started a run")
                model.openStatistics()

                await gate.open()
                let landed = await waitUntil { model.arrivalNotice?.origin == .run }
                #expect(landed, "the run never landed")
                #expect(model.route == .statistics, "the run took the page back")
                #expect(model.transcript == nil, "the run's words went into the window")
                #expect(model.selectedEntryID == nil)
                #expect(model.player == nil, "the run's audio stayed in the player with nothing to play it for")
                #expect(model.sourceFileURL == nil)
                #expect(model.phase == .idle)
                _ = try await savedOutOfSight(model)
            }
        }

        @Test("a take that finishes after the user opened another entry is saved with its own audio, and the entry keeps its own")
        func recordingPairsWithItsSource() async throws {
            let fixture = try makeSilentWAV(label: "take")
            defer { try? FileManager.default.removeItem(at: fixture) }
            try await withMocksCleared([.transcriber, .audioSource]) {
                let gate = MockTranscriberGate()
                defer { Task { await gate.open() } }
                await MockAudioSourceRegistry.shared.install(kind: .mic, fixtureURL: fixture)
                await MockTranscriberRegistry.shared.install(engineID: nil, response: heldMock(gate))

                let model = makeModel()
                model.useStreaming = false
                model.selectedModel = "openai_whisper-tiny"
                model.recordingCountInSeconds = 0

                model.startRecording(source: .microphone)
                let recording = await waitUntil { model.takeInProgress }
                #expect(recording)

                model.stopRecordingAndTranscribe()
                let transcribing = await waitUntil { model.takeTranscription?.file == fixture }
                #expect(transcribing)

                let other = try await openOtherEntry(in: model)
                #expect(model.sourceFileURL == other.audio)
                try #require(model.transcript?.text.contains("own words") != true, "the take must still be transcribing")

                await gate.open()
                let landed = await waitUntil { model.arrivalNotice?.origin == .take }
                #expect(landed, "the take never landed")
                #expect(model.selectedEntryID == other.id, "the take took the entry the user opened")
                #expect(model.sourceFileURL == other.audio, "the entry lost its own audio to the take")
                #expect(playerURL(model) == other.audio, "the entry would play the take's audio")
                let saved = await model.library.list().filter { $0.id != other.id }
                let take = try #require(saved.first)
                let stored = try await model.library.load(take.id).document
                #expect(stored.transcript.text.contains("own words"), mockWentMissing)
                #expect(
                    stored.audioURL?.deletingLastPathComponent().lastPathComponent == take.bundleURL.lastPathComponent,
                    "the take keeps its own recording"
                )
            }
        }

        @Test("the bridge's transcribeFile, sent while another page shows, brings up the run's page as a drop does, and the run lands there")
        func bridgeRunLandsOnItsPage() async throws {
            try await withMocksCleared(.transcriber) {
                await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "the run's own words")]
                ))
                let model = makeModel()
                let server = try ParolaAutomationServer(model: model)
                let commands = Dictionary(uniqueKeysWithValues: server.transcriptCommands().map { ($0.name, $0) })
                let command = try #require(commands["transcribeFile"])
                let wav = try makeSilentWAV(label: "bridge")
                defer { try? FileManager.default.removeItem(at: wav) }
                model.openStatistics()

                _ = try await command.handler(
                    try command.validate(AutomationArgs(["path": .string(wav.path)])), AutomationContext(model: model, server: server)
                )
                #expect(model.route == .transcript, "a drop shows the page its run goes on")

                let landed = await waitUntil { model.phase == .ready && model.selectedEntryID != nil }
                #expect(landed, "the run never opened on its page")
                #expect(model.transcript?.text.contains("own words") == true, mockWentMissing)
                #expect(model.arrivalNotice == nil)
                withExtendedLifetime(server) {}
            }
        }

        @Test("the bridge's transcribeFile, sent while a failed take waits for its Dismiss and another page shows, brings up the run's page, and the run lands there")
        func bridgeRunOverAFailedTakeLandsOnItsPage() async throws {
            try await withMocksCleared(.transcriber) {
                await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "the run's own words")]
                ))
                let model = makeModel()
                let server = try ParolaAutomationServer(model: model)
                let commands = Dictionary(uniqueKeysWithValues: server.transcriptCommands().map { ($0.name, $0) })
                let command = try #require(commands["transcribeFile"])
                let wav = try makeSilentWAV(label: "bridge-failed-take")
                defer { try? FileManager.default.removeItem(at: wav) }
                model.installTestTake(source: .microphone)
                model.updateSession(of: model.recording?.takeID) { $0.fail("The recording stopped.") }
                defer { model.endTestTake() }
                try #require(model.stageHoldsTake, "the failed take should still hold its Stage")
                model.openStatistics()

                _ = try await command.handler(
                    try command.validate(AutomationArgs(["path": .string(wav.path)])), AutomationContext(model: model, server: server)
                )
                #expect(model.route == .transcript, "a failed take parks nothing, so the run's page comes up")

                let landed = await waitUntil { model.phase == .ready && model.selectedEntryID != nil }
                #expect(landed, "the run never opened on its page")
                #expect(model.transcript?.text.contains("own words") == true, mockWentMissing)
                #expect(model.arrivalNotice == nil)
                withExtendedLifetime(server) {}
            }
        }

        /// The ways the user hands Parola a file, besides a drop on the window.
        enum Opening: String, CaseIterable, Sendable {
            case openPanel, openRecent, openWith
        }

        @Test("a file the user opens from another page brings up the run's page, as a drop does, and the run lands there", arguments: Opening.allCases)
        func openedFileShowsItsPage(_ opening: Opening) async throws {
            try await withMocksCleared(.transcriber) {
                await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "the run's own words")]
                ))
                let picker = TestFilePicker()
                let model = makeModel(picker: picker)
                let wav = try makeSilentWAV(label: "opened-\(opening.rawValue)")
                defer { try? FileManager.default.removeItem(at: wav) }
                model.openStatistics()

                switch opening {
                case .openPanel:
                    await picker.queueInputResponse([wav])
                    model.presentOpenPanel()
                case .openRecent:
                    model.openRecentFile(wav)
                case .openWith:
                    model.collectOpenedFile(wav)
                }

                let landed = await waitUntil { model.phase == .ready && model.selectedEntryID != nil }
                #expect(landed, "the run never opened on its page")
                #expect(model.route == .transcript, "the run started off the page it shows on")
                #expect(model.transcript?.text.contains("own words") == true, mockWentMissing)
                #expect(model.arrivalNotice == nil)
            }
        }

        @Test("a Shortcut sent from another page leaves the page alone, and its run is on the transcript page when the user goes there")
        func shortcutRunWaitsOnItsPage() async throws {
            try await withMocksCleared(.transcriber) {
                let gate = MockTranscriberGate()
                defer { Task { await gate.open() } }
                await MockTranscriberRegistry.shared.install(engineID: nil, response: heldMock(gate))
                let model = makeModel()
                let wav = try makeSilentWAV(label: "shortcut")
                defer { try? FileManager.default.removeItem(at: wav) }
                model.openStatistics()

                let shortcut = Task { try await model.transcribeFileFromIntent(wav) }
                let started = await waitUntil { model.fileTranscribeTask != nil }
                try #require(started, "the Shortcut never started a run")
                #expect(model.route == .statistics, "a Shortcut changed the page")
                #expect(model.sourceFileURL == wav, "the run started out of sight, so its page would show nothing")
                model.goHome()
                await gate.open()

                let landed = await waitUntil { model.selectedEntryID != nil }
                #expect(landed, "the run never opened on its page")
                #expect(model.transcript?.text.contains("own words") == true, mockWentMissing)
                #expect(model.arrivalNotice == nil, "the run landed out of sight though its page was up")
                let text = try await shortcut.value
                #expect(text.contains("own words"))
            }
        }

        @Test("a file run started over an open entry that finishes while another page shows lets go of that entry too, whose audio it had taken")
        func fileRunOverAnEntryLeavesAnotherPage() async throws {
            try await withMocksCleared(.transcriber) {
                let gate = MockTranscriberGate()
                defer { Task { await gate.open() } }
                await MockTranscriberRegistry.shared.install(engineID: nil, response: heldMock(gate))

                let model = makeModel()
                let earlier = try await openOtherEntry(in: model)
                let wav = try makeSilentWAV(label: "over-entry")
                defer { try? FileManager.default.removeItem(at: wav) }

                model.transcribe(fileURL: wav)
                await model.awaitDuplicateCheck()
                try #require(model.fileTranscribeTask != nil, "the import never started a run")
                #expect(model.sourceFileURL == wav, "the run takes the player from the entry it started over")
                model.openStatistics()

                await gate.open()
                let landed = await waitUntil { model.arrivalNotice?.origin == .run }
                #expect(landed, "the run never landed")
                let letGo = await waitUntil { model.transcript == nil }
                #expect(letGo, "the entry stayed loaded over the run's audio")
                #expect(model.route == .statistics)
                #expect(model.selectedEntryID == nil)
                #expect(model.player == nil)
                #expect(model.phase == .idle)
                _ = try await savedOutOfSight(model, besides: earlier.id)
            }
        }

        @Test("a YouTube transcription that finishes after the user opened an entry is saved with its own audio, and the entry stays open")
        func youtubeRunLeavesTheOpenedEntry() async throws {
            let fixture = try makeSilentWAV(label: "youtube")
            defer { try? FileManager.default.removeItem(at: fixture) }
            try await withMocksCleared([.transcriber]) {
                let gate = MockTranscriberGate()
                defer { Task { await gate.open() } }
                await MockTranscriberRegistry.shared.install(engineID: nil, response: heldMock(gate))

                let model = makeModel()
                model.linkFetcher = FixtureLinkFetcher(fixtureURL: fixture)
                model.transcribeYouTube(urlString: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
                let fetched = await waitUntil { model.sourceFileURL == fixture }
                #expect(fetched)

                let other = try await openOtherEntry(in: model)
                #expect(model.sourceFileURL == other.audio)
                try #require(model.transcript?.text.contains("own words") != true, "the fetch's run must still be in flight")

                await gate.open()
                let landed = await waitUntil { model.arrivalNotice?.origin == .run }
                #expect(landed, "the fetched run never landed")
                #expect(model.selectedEntryID == other.id, "the run took the entry the user opened")
                #expect(model.sourceFileURL == other.audio, "the entry lost its own audio to the fetched file")
                #expect(playerURL(model) == other.audio)
                _ = try await savedOutOfSight(model, besides: other.id)
            }
        }
    }
}
