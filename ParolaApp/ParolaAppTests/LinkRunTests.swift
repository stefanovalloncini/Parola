import Foundation
import Observation
import Testing
import os
@testable import Parola
import ParolaCore
import ParolaTestSupport

/// Holds a fetch until the test lets it finish.
actor FetchGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

/// Reports a title and half the download, then hands back the fixture, or an owned copy of it the way yt-dlp's lands.
final class ScriptedLinkFetcher: LinkFetcher {
    let fixture: URL
    let metadata: LinkMetadata
    let gate: FetchGate?
    let owned: Bool
    let failure: LinkDownloadFailure?
    let ignoresCancel: Bool
    let captions: FetchedCaptions?
    private let count = OSAllocatedUnfairLock(initialState: 0)
    private let folders = OSAllocatedUnfairLock<[URL]>(initialState: [])

    static let talk = LinkMetadata(
        title: "A talk", webpageURL: URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"), id: "dQw4w9WgXcQ", duration: 0.3
    )

    init(
        fixture: URL,
        metadata: LinkMetadata = ScriptedLinkFetcher.talk,
        gate: FetchGate? = nil,
        owned: Bool = false,
        failure: LinkDownloadFailure? = nil,
        ignoresCancel: Bool = false,
        captions: FetchedCaptions? = nil
    ) {
        self.fixture = fixture
        self.metadata = metadata
        self.gate = gate
        self.owned = owned
        self.failure = failure
        self.ignoresCancel = ignoresCancel
        self.captions = captions
    }

    var fetches: Int { count.withLock { $0 } }
    var workingFolders: [URL] { folders.withLock { $0 } }

    func fetchCaptions(url: URL, language: String?) async throws -> FetchedCaptions {
        await gate?.wait()
        guard let captions else { throw ParolaError.linkDownloadFailed(LinkDownloadFailure(reason: .noCaptions)) }
        return captions
    }

    func fetchAudio(url: URL, progress: @escaping @Sendable (LinkFetchEvent) -> Void) async throws -> FetchedMedia {
        count.withLock { $0 += 1 }
        progress(.metadata(metadata))
        progress(.downloading(fraction: 0.5))
        await gate?.wait()
        if !ignoresCancel { try Task.checkCancellation() }
        if let failure { throw ParolaError.linkDownloadFailed(failure) }
        guard owned else { return FetchedMedia(fileURL: fixture, metadata: metadata) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("parola-yt-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("audio.wav")
        try FileManager.default.copyItem(at: fixture, to: file)
        folders.withLock { $0.append(folder) }
        return FetchedMedia(fileURL: file, metadata: metadata, workingDirectory: folder)
    }
}

/// Every phase the model passes through, in order; a repeat of the same case counts once.
@MainActor
final class PhaseRecorder {
    private(set) var names: [String] = []
    private let model: AppModel

    init(_ model: AppModel) {
        self.model = model
        track()
    }

    private func track() {
        let name = ParolaAutomationServer.phaseName(for: model)
        if names.last != name { names.append(name) }
        withObservationTracking { _ = ParolaAutomationServer.phaseName(for: model) } onChange: { [weak self] in
            Task { @MainActor in self?.track() }
        }
    }
}

func makeLinkFixtureWAV(frames: Int = 4800) throws -> URL {
    var data = Data()
    func ascii(_ s: String) { data.append(contentsOf: Array(s.utf8)) }
    func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    ascii("RIFF"); le32(UInt32(36 + frames * 2)); ascii("WAVE")
    ascii("fmt "); le32(16); le16(1); le16(1); le32(16_000); le32(32_000); le16(2); le16(16)
    ascii("data"); le32(UInt32(frames * 2))
    data.append(Data(count: frames * 2))
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("parola-link-\(UUID().uuidString).wav")
    try data.write(to: url)
    return url
}

extension TranscriberMockSuites {
    @MainActor
    @Suite("Link run", .serialized, .timeLimit(.minutes(1)))
    struct LinkRunTests {
        private static let link = "https://youtu.be/dQw4w9WgXcQ"
        private static let page = ScriptedLinkFetcher.talk.webpageURL

        private func makeExportFolder() throws -> URL {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("parola-link-exports-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        private func makeModel(fetcher: ScriptedLinkFetcher) -> AppModel {
            AppModel(bootstrap: AppBootstrap(
                mode: .test,
                library: makeTempLibraryURL("link-run"),
                defaultsOverride: temporaryDefaults(),
                sideEffects: [],
                filePicker: TestFilePicker(),
                clock: ContinuousClock(),
                linkFetcher: fetcher
            ))
        }

        private static let words = MockTranscriberResponse(
            segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "the video's own words")]
        )

        @Test("a link shows its download, then lands through the file run with its origin")
        func phasesInOrderAndHandoff() async throws {
            let fixture = try makeLinkFixtureWAV()
            defer { try? FileManager.default.removeItem(at: fixture) }
            try await withMocksCleared([.transcriber]) {
                await MockTranscriberRegistry.shared.install(engineID: nil, response: Self.words)
                let gate = FetchGate()
                defer { Task { await gate.open() } }
                let fetcher = ScriptedLinkFetcher(fixture: fixture, gate: gate)
                let model = makeModel(fetcher: fetcher)
                let phases = PhaseRecorder(model)

                #expect(model.transcribeYouTube(urlString: Self.link) == .started)
                #expect(model.phase == .fetchingLink(title: nil, progress: nil))
                await waitUntil { model.phase == .fetchingLink(title: "A talk", progress: 0.5) }

                await gate.open()
                await waitUntil { model.phase == .ready && model.transcript?.text.contains("own words") == true }
                let entry = try #require(try await model.fileRunLanding?.entry.value)

                #expect(Array(phases.names.prefix(2)) == ["idle", "fetchingLink"], "\(phases.names)")
                #expect(phases.names.last == "ready")
                let fetchingLinkCount = phases.names.filter { $0 == "fetchingLink" }.count
                #expect(fetchingLinkCount == 1)
                let thirdPhaseIsLoading = phases.names.dropFirst(2).first.map { ["loadingModel", "downloadingModel", "transcribing"].contains($0) }
                #expect(thirdPhaseIsLoading == true)
                #expect(model.sourceFileURL == fixture)
                #expect(model.transcript?.sourceURL == Self.page)
                #expect(entry.manifest.source == .web)
                #expect(entry.title == "A talk")
                #expect(model.linkRunTitle?.file == fixture && model.linkRunTitle?.title == "A talk")
                #expect(!model.recentFiles.contains(fixture))
                #expect(fetcher.fetches == 1)
            }
        }

        /// Driven by batch events: a real queue reads the file through AVFoundation, which a wedged FIFO test can stall.
        @Test("a link handed over while a batch runs waits for the batch")
        func linkParksBehindABatch() async throws {
            let fixture = try makeLinkFixtureWAV()
            defer { try? FileManager.default.removeItem(at: fixture) }
            try await withMocksCleared([.transcriber]) {
                await MockTranscriberRegistry.shared.install(engineID: nil, response: Self.words)
                let fetcher = ScriptedLinkFetcher(fixture: fixture)
                let model = makeModel(fetcher: fetcher)
                let job = BatchJob(url: URL(fileURLWithPath: "/tmp/parola-batch-file.wav"))
                model.batchJobs = [job]
                model.batchTask = Task {}
                await model.handleBatchEvent(.started(jobID: job.id))
                let batchPhase = model.phase

                #expect(model.transcribeYouTube(urlString: Self.link) == .parked)

                #expect(model.deferredLinks == [.transcribe(Self.link)])
                #expect(model.phase == batchPhase)
                await settle()
                #expect(fetcher.fetches == 0)

                model.batchJobs[0].status = .done
                await model.handleBatchEvent(.finished)

                await waitUntil { fetcher.fetches == 1 }
                await waitUntil { model.phase == .ready && model.transcript?.sourceURL == Self.page }
                #expect(model.deferredLinks.isEmpty)
            }
        }

        @Test("a link whose title yt-dlp didn't give lands under the dated web-video name, still pointing at its page")
        func untitledLinkFallsBack() async throws {
            let fixture = try makeLinkFixtureWAV()
            defer { try? FileManager.default.removeItem(at: fixture) }
            try await withMocksCleared([.transcriber]) {
                await MockTranscriberRegistry.shared.install(engineID: nil, response: Self.words)
                let model = makeModel(fetcher: ScriptedLinkFetcher(fixture: fixture, metadata: LinkMetadata()))

                model.transcribeYouTube(urlString: Self.link)
                await waitUntil { model.phase == .ready && model.fileRunLanding != nil }
                let entry = try #require(try await model.fileRunLanding?.entry.value)

                #expect(entry.title.hasPrefix(String(localized: "Web video — \("")")))
                #expect(model.transcript?.sourceURL == URL(string: Self.link))
                #expect(model.linkRunTitle == nil)
            }
        }

        @Test("a landed link's audio moves into its entry, playback follows it, and the working folder goes")
        func landingConsumesTheDownload() async throws {
            let fixture = try makeLinkFixtureWAV()
            defer { try? FileManager.default.removeItem(at: fixture) }
            try await withMocksCleared([.transcriber]) {
                await MockTranscriberRegistry.shared.install(engineID: nil, response: Self.words)
                let fetcher = ScriptedLinkFetcher(fixture: fixture, owned: true)
                let model = makeModel(fetcher: fetcher)

                model.transcribeYouTube(urlString: Self.link)
                await waitUntil { model.phase == .ready && model.fileRunLanding != nil }
                let entry = try #require(try await model.fileRunLanding?.entry.value)
                let folder = try #require(fetcher.workingFolders.first)
                await waitUntil { !FileManager.default.fileExists(atPath: folder.path) }

                let audio = try #require(try await model.library.load(entry.id).document.audioURL)
                #expect(FileManager.default.fileExists(atPath: audio.path))
                #expect(model.sourceFileURL == audio)
                await waitUntil { model.currentTranscriptTitle == "A talk" }
            }
        }

        @Test("a link whose transcription fails or is cancelled leaves no working folder", arguments: [false, true])
        func failedOrCancelledRunCleansUp(cancel: Bool) async throws {
            let fixture = try makeLinkFixtureWAV()
            defer { try? FileManager.default.removeItem(at: fixture) }
            try await withMocksCleared([.transcriber]) {
                let held = MockTranscriberGate()
                defer { Task { await held.open() } }
                let failing = MockTranscriberResponse(failure: MockTranscriberFailure(code: .transcriptionFailed, message: "boom"))
                var holding = Self.words
                holding.gate = held
                await MockTranscriberRegistry.shared.install(engineID: nil, response: cancel ? holding : failing)
                let fetcher = ScriptedLinkFetcher(fixture: fixture, owned: true)
                let model = makeModel(fetcher: fetcher)

                model.transcribeYouTube(urlString: Self.link)
                await waitUntil { !fetcher.workingFolders.isEmpty && model.sourceFileURL != nil }
                let folder = try #require(fetcher.workingFolders.first)
                if cancel {
                    model.cancelCurrentWork()
                } else {
                    await waitUntil { model.phase == .failed(message: "Transcription failed: boom") }
                }

                await waitUntil { !FileManager.default.fileExists(atPath: folder.path) }
            }
        }

        @Test("the link's handoff leaves a duplicate check a file started during the download alone")
        func handoffKeepsAPendingDuplicateCheck() async throws {
            let fixture = try makeLinkFixtureWAV()
            defer { try? FileManager.default.removeItem(at: fixture) }
            try await withMocksCleared([.transcriber]) {
                await MockTranscriberRegistry.shared.install(engineID: nil, response: Self.words)
                let gate = FetchGate()
                let model = makeModel(fetcher: ScriptedLinkFetcher(fixture: fixture, gate: gate))
                model.transcribeYouTube(urlString: Self.link)
                let pendingCheck = Task<Void, Never> { try? await Task.sleep(for: .seconds(30)) }
                defer { pendingCheck.cancel() }
                model.duplicateCheckTask = pendingCheck

                await gate.open()
                await waitUntil { model.sourceFileURL == fixture }

                #expect(model.duplicateCheckTask == pendingCheck)
                #expect(!pendingCheck.isCancelled)
                model.duplicateCheckTask = nil
                model.cancelCurrentWork()
            }
        }

        @Test("a file opened during a link's download is transcribed, whichever finishes first")
        func fileOpenedDuringTheFetchSurvives() async throws {
            let fixture = try makeLinkFixtureWAV()
            // Large enough that hashing it outlasts the link's handoff.
            let file = try makeLinkFixtureWAV(frames: 16_000 * 600)
            defer {
                try? FileManager.default.removeItem(at: fixture)
                try? FileManager.default.removeItem(at: file)
            }
            try await withMocksCleared([.transcriber]) {
                await MockTranscriberRegistry.shared.install(engineID: nil, response: Self.words)
                let gate = FetchGate()
                let model = makeModel(fetcher: ScriptedLinkFetcher(fixture: fixture, gate: gate))
                model.transcribeYouTube(urlString: Self.link)
                await waitUntil { model.phase == .fetchingLink(title: "A talk", progress: 0.5) }

                model.transcribe(fileURL: file)
                await gate.open()

                await waitUntil(timeoutMs: 20_000) {
                    model.phase == .ready && model.transcript?.sourceURL == file && model.fileRunLanding != nil
                }
                let entry = try #require(try await model.fileRunLanding?.entry.value)
                #expect(entry.manifest.source == .file)
                #expect(model.sourceFileURL == file)
            }
        }

        @Test("a re-run started during a link's download replaces the download and lands")
        func reRunStartedDuringTheFetchSurvives() async throws {
            let fixture = try makeLinkFixtureWAV()
            let audio = try makeLinkFixtureWAV(frames: 5000)
            defer {
                try? FileManager.default.removeItem(at: fixture)
                try? FileManager.default.removeItem(at: audio)
            }
            try await withMocksCleared([.transcriber]) {
                let held = MockTranscriberGate()
                defer { Task { await held.open() } }
                var response = MockTranscriberResponse(segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "the re-run's words")])
                response.gate = held
                await MockTranscriberRegistry.shared.install(engineID: nil, response: response)
                let gate = FetchGate()
                let fetcher = ScriptedLinkFetcher(fixture: fixture, gate: gate)
                let model = makeModel(fetcher: fetcher)
                let entry = try await model.library.add(
                    transcript: Transcript(
                        segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "the old take")],
                        language: "en", modelName: "openai_whisper-tiny"
                    ),
                    audioSource: audio
                )
                model.refreshLibrary()
                await waitUntil { model.libraryEntry(id: entry.id) != nil }
                model.transcribeYouTube(urlString: Self.link)
                await waitUntil { fetcher.fetches == 1 }
                model.loadEntry(entry.id)
                await waitUntil { model.selectedEntryID == entry.id && model.transcript != nil }

                model.retranscribeCurrentEntry(model: model.selectedModel, language: "en")
                await gate.open()
                await settle()
                await held.open()

                await waitUntil(timeoutMs: 10_000) { model.retranscribeRequest == nil && model.phase == .ready }
                let stored = try await model.library.load(entry.id).document.transcript
                #expect(stored.segments.first?.text == "the re-run's words")
                #expect(model.sourceFileURL != fixture)
                #expect(model.fileRunLanding == nil)
            }
        }

        @Test("a link whose save fails says so, writes no export beside its download, and the note doesn't hide it")
        func saveFailureOutranksTheExportNote() async throws {
            let fixture = try makeLinkFixtureWAV()
            defer { try? FileManager.default.removeItem(at: fixture) }
            try await withMocksCleared([.transcriber]) {
                await MockTranscriberRegistry.shared.install(engineID: nil, response: Self.words)
                let fetcher = ScriptedLinkFetcher(fixture: fixture, owned: true)
                let model = makeModel(fetcher: fetcher)
                let srtPreset = model.exportPresets.first { $0.spec.format == .srt }
                let srt = try #require(srtPreset)
                model.autoExportRules = [AutoExportRule(sourceExtensions: [], presetIDs: [srt.id])]
                let libraryURL = model.library.libraryURL
                try FileManager.default.removeItem(at: libraryURL)
                try Data("not a folder".utf8).write(to: libraryURL)
                defer { try? FileManager.default.removeItem(at: libraryURL) }

                model.transcribeYouTube(urlString: Self.link)
                await waitUntil { model.nonFatalWarning != nil }
                await settle(for: .milliseconds(500))

                #expect(model.nonFatalWarning?.contains("couldn't save it to your library") == true)
                let folder = try #require(fetcher.workingFolders.first)
                defer { try? FileManager.default.removeItem(at: folder) }
                let left = try FileManager.default.contentsOfDirectory(atPath: folder.path)
                #expect(left == ["audio.wav"], "the kept download must be the only thing in its folder")
            }
        }

        @Test("a download that finishes just as it's cancelled leaves no folder behind")
        func lateDownloadAfterCancelCleansUp() async throws {
            let fixture = try makeLinkFixtureWAV()
            defer { try? FileManager.default.removeItem(at: fixture) }
            let gate = FetchGate()
            let fetcher = ScriptedLinkFetcher(fixture: fixture, gate: gate, owned: true, ignoresCancel: true)
            let model = makeModel(fetcher: fetcher)

            model.transcribeYouTube(urlString: Self.link)
            await waitUntil { fetcher.fetches == 1 }
            model.cancelCurrentWork()
            await gate.open()

            await waitUntil { fetcher.workingFolders.count == 1 }
            let folder = try #require(fetcher.workingFolders.first)
            await waitUntil { !FileManager.default.fileExists(atPath: folder.path) }
            #expect(model.phase == .idle)
            #expect(model.sourceFileURL != fetcher.workingFolders.first?.appendingPathComponent("audio.wav"))
        }

        @Test("fetched captions land with the video's title and page as a web entry, and auto-export writes them under that title")
        func captionsLanding() async throws {
            let fixture = try makeLinkFixtureWAV()
            defer { try? FileManager.default.removeItem(at: fixture) }
            let captions = FetchedCaptions(
                transcript: Transcript(
                    segments: [TranscriptSegment(id: 0, start: 0, end: 2, text: "the video's own captions")],
                    language: "en", modelName: "youtube-subs", sourceURL: Self.page
                ),
                metadata: ScriptedLinkFetcher.talk
            )
            let model = makeModel(fetcher: ScriptedLinkFetcher(fixture: fixture, captions: captions))
            let srt = try #require(model.exportPresets.first { $0.spec.format == .srt })
            model.autoExportRules = [AutoExportRule(sourceExtensions: [], presetIDs: [srt.id])]
            let chosen = try makeExportFolder()
            defer { try? FileManager.default.removeItem(at: chosen) }
            #expect(model.setAutoExportFolder(chosen))

            #expect(model.fetchYouTubeSubs(urlString: Self.link) == .started)

            await waitUntil { model.phase == .ready && model.selectedEntryID != nil }
            let loaded = try await model.library.load(try #require(model.selectedEntryID))
            #expect(loaded.entry.title == "A talk")
            #expect(loaded.entry.manifest.source == .web)
            #expect(loaded.document.transcript.sourceURL == Self.page)
            #expect(model.transcript?.text.contains("own captions") == true)
            let exported = chosen.appendingPathComponent("A talk.srt")
            await waitUntil { FileManager.default.fileExists(atPath: exported.path) }
            #expect(try String(contentsOf: exported, encoding: .utf8).contains("own captions"))
            #expect(model.nonFatalWarning == nil)
        }

        @Test("a link whose download ends after the user opened an entry leaves that entry up, its player and phase too, and lands with a toast")
        func linkDownloadedAfterAnOpenLandsOutOfSight() async throws {
            let fixture = try makeLinkFixtureWAV()
            defer { try? FileManager.default.removeItem(at: fixture) }
            try await withMocksCleared([.transcriber]) {
                await MockTranscriberRegistry.shared.install(engineID: nil, response: Self.words)
                let gate = FetchGate()
                defer { Task { await gate.open() } }
                let model = makeModel(fetcher: ScriptedLinkFetcher(fixture: fixture, gate: gate))
                let older = try await LibraryStore(libraryURL: model.library.libraryURL, extraIndexer: nil).add(
                    transcript: Transcript(
                        segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "an older entry")], language: "en", modelName: "stub"
                    ),
                    audioSource: nil
                )

                #expect(model.transcribeYouTube(urlString: Self.link) == .started)
                _ = try await model.openEntry(older.id)
                let phases = PhaseRecorder(model)
                await gate.open()

                let landed = await waitUntil { model.arrivalNotice?.origin == .run }
                #expect(landed, "the link never landed")
                #expect(model.selectedEntryID == older.id, "the link took the entry the user opened")
                #expect(model.transcript?.text == "an older entry")
                #expect(model.player == nil, "the download took the player from the entry")
                let seen = phases.names
                #expect(seen == ["ready"], "the run's progress went over the entry")
                let fetched = await model.library.list().filter { $0.id != older.id }
                let entry = try #require(fetched.first)
                #expect(entry.title == "A talk")
                #expect(model.arrivalNotice?.state == .saved(entry.id))
            }
        }

        @Test("captions that arrive after the user opened an entry are saved out of sight with a toast, and the entry stays open")
        func captionsLeaveTheOpenedEntry() async throws {
            let fixture = try makeLinkFixtureWAV()
            defer { try? FileManager.default.removeItem(at: fixture) }
            let captions = FetchedCaptions(
                transcript: Transcript(
                    segments: [TranscriptSegment(id: 0, start: 0, end: 2, text: "the video's own captions")],
                    language: "en", modelName: "youtube-subs", sourceURL: Self.page
                ),
                metadata: ScriptedLinkFetcher.talk
            )
            let gate = FetchGate()
            defer { Task { await gate.open() } }
            let model = makeModel(fetcher: ScriptedLinkFetcher(fixture: fixture, gate: gate, captions: captions))
            // A store with no Spotlight indexer: the real one can hang the test host.
            let seed = LibraryStore(libraryURL: model.library.libraryURL, extraIndexer: nil)
            let older = try await seed.add(
                transcript: Transcript(
                    segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "an older entry")], language: "en", modelName: "stub"
                ),
                audioSource: nil
            )

            #expect(model.fetchYouTubeSubs(urlString: Self.link) == .started)
            _ = try await model.openEntry(older.id)
            await gate.open()

            let landed = await waitUntil { model.arrivalNotice?.origin == .run }
            #expect(landed, "the captions never landed")
            #expect(model.selectedEntryID == older.id, "the captions took the entry the user opened")
            #expect(model.transcript?.text == "an older entry")
            let fetched = await model.library.list().filter { $0.id != older.id }
            let entry = try #require(fetched.first)
            #expect(entry.title == "A talk")
            #expect(model.arrivalNotice?.state == .saved(entry.id))
        }

        @Test("the fetch pane ends on the newest folded state, whatever order two readers deliver in")
        func fetchPaneKeepsTheNewestState() async {
            let model = makeModel(fetcher: ScriptedLinkFetcher(fixture: URL(fileURLWithPath: "/tmp/never.wav")))
            model.phase = .fetchingLink(title: nil, progress: nil)
            let handler = model.makeLinkFetchHandler(runToken: model.nextFileRunToken())

            await withTaskGroup(of: Void.self) { group in
                group.addTask { for _ in 0..<2000 { handler(.metadata(LinkMetadata(title: "A talk"))) } }
                group.addTask { for _ in 0..<2000 { handler(.downloading(fraction: 0.5)) } }
            }

            await waitUntil { model.phase == .fetchingLink(title: "A talk", progress: 0.5) }
            await settle()
            #expect(model.phase == .fetchingLink(title: "A talk", progress: 0.5))
        }

        @Test("Retry after a failed transcription fetches the link again")
        func retryReplaysTheLink() async throws {
            let fixture = try makeLinkFixtureWAV()
            defer { try? FileManager.default.removeItem(at: fixture) }
            try await withMocksCleared([.transcriber]) {
                await MockTranscriberRegistry.shared.install(
                    engineID: nil,
                    response: MockTranscriberResponse(failure: MockTranscriberFailure(code: .transcriptionFailed, message: "boom"))
                )
                let fetcher = ScriptedLinkFetcher(fixture: fixture)
                let model = makeModel(fetcher: fetcher)

                model.transcribeYouTube(urlString: Self.link)
                await waitUntil { model.phase == .failed(message: "Transcription failed: boom") }

                #expect(model.failedLink == .transcribe(Self.link))
                #expect(model.failedFileURL == nil)
                #expect(model.canRetryFailedTranscription)

                await MockTranscriberRegistry.shared.install(engineID: nil, response: Self.words)
                await model.unloadTranscriptionSession()
                model.retryFailedTranscription()

                await waitUntil { fetcher.fetches == 2 }
                await waitUntil { model.phase == .ready && model.transcript?.text.contains("own words") == true }
            }
        }

        @Test("a link run is checkpointed by its link, and the recovery fetches it again")
        func recoveryReplaysTheLink() async throws {
            let fixture = try makeLinkFixtureWAV()
            defer { try? FileManager.default.removeItem(at: fixture) }
            let gate = FetchGate()
            defer { Task { await gate.open() } }
            let first = makeModel(fetcher: ScriptedLinkFetcher(fixture: fixture, gate: gate))

            first.transcribeYouTube(urlString: Self.link)
            await waitUntil { first.activeRecoveryFileURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
            let saved = try Data(contentsOf: try #require(first.activeRecoveryFileURL))
            let checkpoint = try JSONDecoder().decode(RecoveryCheckpoint.self, from: saved)
            #expect(checkpoint.sourceURL == URL(string: Self.link))
            #expect(checkpoint.source == .web)
            #expect(checkpoint.sourceName == Self.link)
            first.cancelCurrentWork()

            let relaunchFetcher = ScriptedLinkFetcher(fixture: fixture, gate: gate)
            let relaunched = makeModel(fetcher: relaunchFetcher)
            try saved.write(to: relaunched.legacyRecoveryFileURL)
            relaunched.loadPendingRecovery()
            #expect(relaunched.pendingRecovery?.sourceURL == URL(string: Self.link))

            relaunched.acceptPendingRecovery()

            await waitUntil { relaunchFetcher.fetches == 1 }
            #expect(relaunched.phase == .fetchingLink(title: "A talk", progress: 0.5) || relaunched.phase == .fetchingLink(title: nil, progress: nil))
            relaunched.cancelCurrentWork()
        }

        @Test("a link's auto-exports go to the auto-export folder under the video's title, never into its download folder")
        func autoExportWritesLinksToTheFolder() async throws {
            let fixture = try makeLinkFixtureWAV()
            defer { try? FileManager.default.removeItem(at: fixture) }
            try await withMocksCleared([.transcriber]) {
                await MockTranscriberRegistry.shared.install(engineID: nil, response: Self.words)
                let model = makeModel(fetcher: ScriptedLinkFetcher(fixture: fixture))
                let srtPreset = model.exportPresets.first { $0.spec.format == .srt }
                let srt = try #require(srtPreset)
                model.autoExportRules = [AutoExportRule(sourceExtensions: [], presetIDs: [srt.id])]
                let chosen = try makeExportFolder()
                defer { try? FileManager.default.removeItem(at: chosen) }
                #expect(model.setAutoExportFolder(chosen))

                model.transcribeYouTube(urlString: Self.link)
                let exported = chosen.appendingPathComponent("A talk.srt")
                await waitUntil { OutputMarker.isMarked(exported) }

                #expect(try String(contentsOf: exported, encoding: .utf8).contains("own words"))
                #expect(OutputMarker.owner(of: exported) == model.selectedEntryID)
                #expect(model.nonFatalWarning == nil)
                #expect(!FileManager.default.fileExists(atPath: fixture.deletingPathExtension().appendingPathExtension("srt").path))
            }
        }
    }
}
