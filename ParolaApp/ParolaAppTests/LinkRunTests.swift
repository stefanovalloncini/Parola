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

/// A link fetcher that reports a title and half the download, then hands back a local file. An owning fetcher
/// copies the fixture into a working folder of its own, the way yt-dlp's download lands.
final class ScriptedLinkFetcher: MediaFetcher {
    let fixture: URL
    let metadata: LinkMetadata
    let gate: FetchGate?
    let owned: Bool
    let failure: LinkDownloadFailure?
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
        failure: LinkDownloadFailure? = nil
    ) {
        self.fixture = fixture
        self.metadata = metadata
        self.gate = gate
        self.owned = owned
        self.failure = failure
    }

    var fetches: Int { count.withLock { $0 } }
    var workingFolders: [URL] { folders.withLock { $0 } }

    func fetch(url: URL, progress: @escaping @Sendable (LinkFetchEvent) -> Void) async throws -> FetchedMedia {
        count.withLock { $0 += 1 }
        progress(.metadata(metadata))
        progress(.downloading(fraction: 0.5))
        await gate?.wait()
        try Task.checkCancellation()
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
        let name = ParolaAutomationServer.phaseName(model.phase)
        if names.last != name { names.append(name) }
        withObservationTracking { _ = model.phase } onChange: { [weak self] in
            Task { @MainActor in self?.track() }
        }
    }
}

func makeLinkFixtureWAV() throws -> URL {
    let frames = 4800
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

        private func makeModel(fetcher: ScriptedLinkFetcher) -> AppModel {
            let model = AppModel(bootstrap: AppBootstrap(
                mode: .test,
                library: makeTempLibraryURL("link-run"),
                defaultsOverride: temporaryDefaults(),
                sideEffects: [],
                filePicker: TestFilePicker(),
                clock: ContinuousClock()
            ))
            model.makeMediaFetcher = { fetcher }
            return model
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
                #expect(phases.names.filter { $0 == "fetchingLink" }.count == 1)
                #expect(phases.names.dropFirst(2).first.map { ["loadingModel", "downloadingModel", "transcribing"].contains($0) } == true)
                #expect(model.sourceFileURL == fixture)
                #expect(model.transcript?.sourceURL == Self.page)
                #expect(entry.manifest.source == .web)
                #expect(entry.title == "A talk")
                #expect(model.linkRunTitle?.file == fixture && model.linkRunTitle?.title == "A talk")
                #expect(!model.recentFiles.contains(fixture))
                #expect(fetcher.fetches == 1)
            }
        }

        /// The batch is driven by its events: a real queue would read the file through AVFoundation, which an
        /// earlier suite's wedged FIFO can leave stuck for the rest of the process.
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
            await waitUntil { FileManager.default.fileExists(atPath: first.recoveryFileURL.path) }
            let saved = try Data(contentsOf: first.recoveryFileURL)
            let checkpoint = try JSONDecoder().decode(RecoveryCheckpoint.self, from: saved)
            #expect(checkpoint.sourceURL == URL(string: Self.link))
            #expect(checkpoint.source == .web)
            #expect(checkpoint.sourceName == Self.link)
            first.cancelCurrentWork()

            let relaunchFetcher = ScriptedLinkFetcher(fixture: fixture, gate: gate)
            let relaunched = makeModel(fetcher: relaunchFetcher)
            try saved.write(to: relaunched.recoveryFileURL)
            relaunched.loadPendingRecovery()
            #expect(relaunched.pendingRecovery?.sourceURL == URL(string: Self.link))

            relaunched.acceptPendingRecovery()

            await waitUntil { relaunchFetcher.fetches == 1 }
            #expect(relaunched.phase == .fetchingLink(title: "A talk", progress: 0.5) || relaunched.phase == .fetchingLink(title: nil, progress: nil))
            relaunched.cancelCurrentWork()
        }

        @Test("auto-export rules skip a link and say so instead of writing into its temporary folder")
        func autoExportSkipsLinks() async throws {
            let fixture = try makeLinkFixtureWAV()
            defer { try? FileManager.default.removeItem(at: fixture) }
            try await withMocksCleared([.transcriber]) {
                await MockTranscriberRegistry.shared.install(engineID: nil, response: Self.words)
                let model = makeModel(fetcher: ScriptedLinkFetcher(fixture: fixture))
                let srt = try #require(model.exportPresets.first { $0.spec.format == .srt })
                model.autoExportRules = [AutoExportRule(sourceExtensions: [], presetIDs: [srt.id])]

                model.transcribeYouTube(urlString: Self.link)
                await waitUntil { model.nonFatalWarning != nil }

                #expect(model.nonFatalWarning == String(
                    localized: "Auto-export skipped this link: its rules save next to the source file, and a link has no folder to save in. Use Export instead."
                ))
                await settle()
                #expect(!FileManager.default.fileExists(atPath: fixture.deletingPathExtension().appendingPathExtension("srt").path))
            }
        }
    }
}
