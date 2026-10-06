import AppKit
import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Split drop routing")
struct DropRoutingTests {

    /// A link that reaches a run fails at once instead of starting a real yt-dlp.
    private func makeModel(features: Set<ParolaFeature> = Set(ParolaFeature.allCases)) -> AppModel {
        let model = AppModel(
            skipBootstrap: true,
            defaults: temporaryDefaults(),
            libraryURL: makeTempLibraryURL("drop"),
            features: features
        )
        model.linkFetcher = FixtureLinkFetcher(failure: LinkDownloadFailure(reason: .toolMissing))
        return model
    }

    private static func media(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/DropRoutingTests/\(name)")
    }

    private static let link = URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!

    @Test("the Transcribe Now half shows the transcript route and keeps the drop order")
    func transcribeNowTakesTheTranscriptRoute() {
        let model = makeModel()
        model.route = .batch
        model.fileTranscribeTask = Task {}
        let first = Self.media("one.wav")
        let second = Self.media("two.mkv")

        model.transcribeNow(urls: [first, second])

        #expect(model.route == .transcript)
        #expect(model.deferredArrivals == [first, second])
        model.fileTranscribeTask?.cancel()
        model.fileTranscribeTask = nil
    }

    @Test("a drop mid-transcription waits instead of killing the run")
    func dropDuringTranscriptionDefers() {
        let model = makeModel()
        model.phase = .transcribing(file: Self.media("running.wav"))
        model.fileTranscribeTask = Task {}

        model.transcribeNow(urls: [Self.media("later.wav")])

        #expect(model.phase == .transcribing(file: Self.media("running.wav")))
        #expect(model.deferredArrivals.map(\.lastPathComponent) == ["later.wav"])
        model.fileTranscribeTask?.cancel()
        model.fileTranscribeTask = nil
    }

    @Test("⌘O mid-transcription waits its turn instead of cancelling the run, and says so")
    func openDuringTranscriptionDefers() async {
        let model = makeModel()
        model.phase = .transcribing(file: Self.media("running.wav"))
        let run = Task {}
        model.fileTranscribeTask = run

        model.handleIncomingFiles([Self.media("later.wav")])
        await settle()

        #expect(!run.isCancelled)
        #expect(model.phase == .transcribing(file: Self.media("running.wav")))
        #expect(model.deferredArrivals.map(\.lastPathComponent) == ["later.wav"])
        #expect(model.exportNotice?.message == "Starts when the current transcription ends.")
        model.fileTranscribeTask = nil
    }

    @Test("Open Recent mid-transcription waits too, and leaves the page where it is")
    func openRecentDuringTranscriptionDefers() async {
        let model = makeModel()
        model.route = .queue
        model.phase = .transcribing(file: Self.media("running.wav"))
        let run = Task {}
        model.fileTranscribeTask = run

        model.openRecentFile(Self.media("recent.m4a"))
        await settle()

        #expect(!run.isCancelled)
        #expect(model.route == .queue)
        #expect(model.deferredArrivals.map(\.lastPathComponent) == ["recent.m4a"])
        model.fileTranscribeTask = nil
    }

    @Test("the toolbar's + stays enabled during a run, since what it opens waits its turn")
    func newMenuStaysEnabled() throws {
        let path = #filePath.replacingOccurrences(
            of: "ParolaAppTests/DropRoutingTests.swift", with: "ParolaApp/Views/ContentToolbar.swift"
        )
        let toolbar = try String(contentsOfFile: path, encoding: .utf8)
        let newMenu = try #require(toolbar.range(of: "private var newMenu: some View {"))
        let end = try #require(toolbar.range(of: "private var newMenuItems", range: newMenu.upperBound..<toolbar.endIndex))
        #expect(!toolbar[newMenu.upperBound..<end.lowerBound].contains(".disabled("))
    }

    @Test("a drop while recording goes to the deferred pile rather than stomping the take")
    func dropWhileRecordingDefers() {
        let model = makeModel()
        model.installTestTake(source: .microphone)

        model.transcribeNow(urls: [Self.media("arrival.wav")])

        #expect(model.deferredArrivals.map(\.lastPathComponent) == ["arrival.wav"])
        #expect(model.recording?.isCapturing == true)
        #expect(model.route == .recording)
    }

    @Test("the Transcribe Now half joins a running batch instead of racing it")
    func transcribeNowJoinsARunningBatch() async {
        let model = makeModel()
        model.batchJobs = [BatchJob(url: Self.media("running.wav"), status: .transcribing)]

        model.transcribeNow(urls: [Self.media("late.wav")])
        await model.awaitBatchImport()

        #expect(model.route == .queue)
        #expect(model.batchJobs.map(\.url.lastPathComponent) == ["running.wav", "late.wav"])
        #expect(model.deferredArrivals.isEmpty)
    }

    @Test("the Add to Queue half appends to the queue and shows it")
    func addToQueueAppends() async {
        let model = makeModel()
        model.batchJobs = [BatchJob(url: Self.media("running.wav"), status: .transcribing)]

        model.addToQueue(urls: [Self.media("a.wav"), Self.media("b.wav")])
        await model.awaitBatchImport()

        #expect(model.route == .queue)
        #expect(model.batchJobs.map(\.url.lastPathComponent) == ["running.wav", "a.wav", "b.wav"])
    }

    @Test("the Add to Queue half never lands a gated build on a failure pane")
    func addToQueueFallsBackWithoutBatch() {
        let model = makeModel(features: [.youtube])
        model.installTestTake(source: .microphone)

        model.addToQueue(urls: [Self.media("a.wav"), Self.media("b.wav")])

        #expect(model.batchJobs.isEmpty)
        #expect(model.deferredArrivals.count == 2)
        #expect(model.recording?.isCapturing == true)
        #expect(model.route == .recording)
    }

    @Test("a dropped folder of mkv files reaches the queue")
    func folderOfMkvReachesTheQueue() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DropRoutingTests-mkv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appendingPathComponent("one.mkv"))
        try Data().write(to: dir.appendingPathComponent("two.mkv"))
        let model = makeModel()
        model.batchJobs = [BatchJob(url: Self.media("running.wav"), status: .transcribing)]

        model.addToQueue(urls: [dir])
        await model.awaitBatchImport()

        #expect(model.batchJobs.map(\.url.lastPathComponent) == ["running.wav", "one.mkv", "two.mkv"])
    }

    @Test("a dropped web link yt-dlp can't fetch never reaches the transcriber")
    func unsupportedLinkIsRejected() {
        let model = makeModel()

        model.transcribeNow(urls: [URL(string: "https://example.com/article")!])

        #expect(model.sourceFileURL == nil)
        #expect(model.deferredArrivals.isEmpty)
        #expect(model.phase == .idle)
    }

    @Test("a link dropped while recording parks instead of taking the phase off the take")
    func linkWhileRecordingParks() {
        let model = makeModel()
        model.installTestTake(source: .microphone)

        model.transcribeNow(urls: [Self.link])

        #expect(model.recording?.isCapturing == true)
        #expect(model.route == .recording)
        #expect(model.deferredLinks == [.transcribe(Self.link.absoluteString)])
        #expect(model.transcribeTaskRunning == false)

        model.endTestTake()
        model.phase = .ready
        model.drainDeferredArrivals()

        #expect(model.deferredLinks.isEmpty)
        #expect(model.transcribeTaskRunning)
        model.cancelCurrentWork()
    }

    @Test("transcribeYouTube parks a link handed straight to it during a take")
    func transcribeYouTubeParksWhileRecording() {
        let model = makeModel()
        model.installTestTake(source: .microphone)

        model.transcribeYouTube(urlString: Self.link.absoluteString)

        #expect(model.recording?.isCapturing == true)
        #expect(model.route == .recording)
        #expect(model.deferredLinks == [.transcribe(Self.link.absoluteString)])
        #expect(model.transcribeTaskRunning == false)
    }

    @Test("a subtitle fetch asked for during a take waits for the take and then runs")
    func fetchYouTubeSubsParksWhileRecording() {
        let model = makeModel()
        model.installTestTake(source: .microphone)

        model.fetchYouTubeSubs(urlString: Self.link.absoluteString)

        #expect(model.recording?.isCapturing == true)
        #expect(model.route == .recording)
        #expect(model.deferredLinks == [.subtitles(Self.link.absoluteString)])
        #expect(model.transcribeTaskRunning == false)

        model.endTestTake()
        model.phase = .ready
        model.drainDeferredArrivals()

        #expect(model.deferredLinks.isEmpty)
        #expect(model.youtubeSubsTask != nil, "the drain must replay the fetch, not a transcription")
        model.cancelCurrentWork()
    }

    @Test("the Add to Queue half parks a link rather than dropping it on the floor")
    func addToQueueParksLink() {
        let model = makeModel()
        model.installTestTake(source: .microphone)

        model.addToQueue(urls: [Self.link])

        #expect(model.deferredLinks == [.transcribe(Self.link.absoluteString)])
        #expect(model.batchJobs.isEmpty)
        #expect(model.recording?.isCapturing == true)
        #expect(model.route == .recording)
    }

    private static let secondLink = URL(string: "https://vimeo.com/76979871")!

    private func linkModel(_ fetcher: ScriptedLinkFetcher) -> AppModel {
        let model = makeModel()
        model.linkFetcher = fetcher
        return model
    }

    @Test("two links dropped on either half: the first starts, the second waits its turn", arguments: [
        AppModel.DropHalf.now, .queue,
    ])
    func everyDroppedLinkIsTaken(half: AppModel.DropHalf) async {
        let gate = FetchGate()
        let fetcher = ScriptedLinkFetcher(fixture: Self.media("never.wav"), gate: gate)
        let model = linkModel(fetcher)

        await model.drop([Self.link, Self.secondLink], on: half).value

        #expect(model.phase == .fetchingLink(title: nil, progress: nil))
        #expect(model.deferredLinks == [.transcribe(Self.secondLink.absoluteString)])
        await waitUntil { fetcher.fetches == 1 }
        model.cancelCurrentWork()
        await gate.open()
    }

    @Test("the waiting link runs once the first one ends")
    func queuedLinkRunsNext() async {
        let fetcher = ScriptedLinkFetcher(
            fixture: Self.media("never.wav"), failure: LinkDownloadFailure(reason: .unavailable(.privateVideo), site: "YouTube")
        )
        let model = linkModel(fetcher)

        model.transcribeNow(urls: [Self.link, Self.secondLink])

        await waitUntil { fetcher.fetches == 2 }
        await waitUntil { model.deferredLinks.isEmpty && !model.transcribeTaskRunning }
    }

    @Test("links dropped with media files wait behind the files instead of vanishing")
    func linksBesideMediaWait() {
        let fetcher = ScriptedLinkFetcher(fixture: Self.media("never.wav"))
        let model = linkModel(fetcher)
        model.fileTranscribeTask = Task {}
        let file = Self.media("talk.wav")

        model.transcribeNow(urls: [file, Self.link, Self.secondLink])

        #expect(model.deferredArrivals == [file])
        #expect(model.deferredLinks == [
            .transcribe(Self.link.absoluteString), .transcribe(Self.secondLink.absoluteString),
        ])
        #expect(fetcher.fetches == 0)
        model.fileTranscribeTask?.cancel()
        model.fileTranscribeTask = nil
    }

    enum DuplicateOutcome: CaseIterable, Sendable {
        case openExistingPolicy
        case sheetDismissed
        case batchSkipsIt
    }

    @Test("a link dropped beside a file the library already holds starts once the file settles", arguments: DuplicateOutcome.allCases)
    func linkBesideADuplicateRuns(outcome: DuplicateOutcome) async throws {
        let file = try makeLinkFixtureWAV()
        let second = try makeLinkFixtureWAV(frames: 4900)
        defer {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: second)
        }
        let gate = FetchGate()
        let fetcher = ScriptedLinkFetcher(fixture: Self.media("never.wav"), gate: gate)
        let model = linkModel(fetcher)
        let known = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "held already")], language: "en", modelName: "tiny"
        )
        _ = try await model.library.add(transcript: known, audioSource: file)
        _ = try await model.library.add(transcript: known, audioSource: second)
        model.duplicateImportPolicy = outcome == .sheetDismissed ? .alwaysAsk : .openExisting

        if outcome == .batchSkipsIt {
            model.addToQueue(urls: [file, second, Self.link])
        } else {
            model.transcribeNow(urls: [file, Self.link])
        }
        if outcome == .sheetDismissed {
            await waitUntil { model.duplicateImport != nil }
            #expect(fetcher.fetches == 0)
            model.dismissDuplicateImport()
        }

        await waitUntil { fetcher.fetches == 1 }
        #expect(model.deferredLinks.isEmpty)
        model.cancelCurrentWork()
        await gate.open()
    }

    @Test("an opened subtitle file and a link both land")
    func subtitleBesideLink() async throws {
        let srt = FileManager.default.temporaryDirectory.appendingPathComponent("parola-drop-\(UUID().uuidString).srt")
        try "1\n00:00:00,000 --> 00:00:01,000\nHello there.\n".write(to: srt, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: srt) }
        let gate = FetchGate()
        let fetcher = ScriptedLinkFetcher(fixture: Self.media("never.wav"), gate: gate)
        let model = linkModel(fetcher)

        model.handleIncomingFiles([srt, Self.link])

        #expect(model.transcript?.text.contains("Hello there.") == true)
        #expect(model.phase == .fetchingLink(title: nil, progress: nil))
        await waitUntil { fetcher.fetches == 1 }
        model.cancelCurrentWork()
        await gate.open()
    }

    @Test("the overlay offers a dragged link the parked plan while a batch runs")
    func linkOverlayDuringABatch() {
        let model = makeModel()
        model.dropDragPayload = .links(count: 1)
        #expect(model.dropZonePlan == .transcribeLink)

        model.batchJobs = [BatchJob(url: Self.media("running.wav"), status: .transcribing)]
        model.batchTask = Task {}

        #expect(model.dropZonePlan == .queueOnly(count: 1))
        #expect(model.transcribeYouTube(urlString: Self.link.absoluteString) == .parked)
        model.batchTask = nil
        model.batchJobs = []
    }

    @Test("a link the window will park gets the same plan a parked file gets")
    func deferredLinkPlanMatchesMediaPlan() {
        for batchEnabled in [true, false] {
            let links = DroppedFiles.plan(
                for: .links(count: 1),
                batchEnabled: batchEnabled,
                youtubeEnabled: true,
                arrivalsDeferred: true
            )
            let media = DroppedFiles.plan(
                for: .media(count: 1),
                batchEnabled: batchEnabled,
                youtubeEnabled: true,
                arrivalsDeferred: true
            )
            #expect(links == media)
        }

        let ready = DroppedFiles.plan(
            for: .links(count: 1),
            batchEnabled: true,
            youtubeEnabled: true,
            arrivalsDeferred: false
        )
        #expect(ready == .transcribeLink)
    }

    @Test("dropped projects never become batch jobs")
    func projectsNeverBecomeBatchJobs() {
        let model = makeModel()

        model.transcribeNow(urls: [Self.media("a.parola"), Self.media("b.parola")])

        #expect(model.batchJobs.isEmpty)
        #expect(model.deferredArrivals.isEmpty)
    }

    @Test("every entry point opens every dropped project, not just the first")
    func everyDroppedProjectOpens() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DropRoutingTests-projects-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let base = dir.appendingPathComponent("second")
        _ = try ParolaDocument.write(
            transcript: Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "second project")],
                language: "en",
                modelName: "stub"
            ),
            audioURL: nil,
            to: base
        )
        let dropped = [Self.media("first.parola"), base.appendingPathExtension("parola")]
        let routes: [(AppModel, [URL]) -> Void] = [
            { $0.transcribeNow(urls: $1) },
            { $0.addToQueue(urls: $1) },
            { $0.handleIncomingFiles($1) },
        ]

        for route in routes {
            let model = makeModel()
            route(model, dropped)

            var opened = false
            for _ in 0..<300 where !opened {
                if model.transcript?.segments.first?.text == "second project" { opened = true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            #expect(opened, "the project behind the first one never opened")
            #expect(model.batchJobs.isEmpty)
        }
    }

    @Test("dropping a PDF does nothing at all")
    func unsupportedFileDoesNothing() {
        let model = makeModel()

        model.transcribeNow(urls: [Self.media("paper.pdf")])
        model.addToQueue(urls: [Self.media("paper.pdf")])

        #expect(model.batchJobs.isEmpty)
        #expect(model.deferredArrivals.isEmpty)
        #expect(model.phase == .idle)
    }

    @Test("the zone plan follows the payload the drag carried in")
    func zonePlanFollowsPayload() {
        let model = makeModel()
        #expect(model.dropZonePlan == .none)

        model.dropDragPayload = .media(count: 2)
        #expect(model.dropZonePlan == .split(count: 2))

        model.installTestTake(source: .microphone)
        #expect(model.dropZonePlan == .queueOnly(count: 2))
    }

    @Test("the overlay stands down while the drag is over the chat composer")
    func composerDragSuppressesTheOverlay() {
        let model = makeModel()
        model.dropDragPayload = .media(count: 1)
        #expect(model.dropZonePlan == .split(count: 1))

        model.dragOverComposer = true
        #expect(model.dropZonePlan == .none)

        model.dragOverComposer = false
        #expect(model.dropZonePlan == .split(count: 1))
    }

    private func folder(holding count: Int) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DropRoutingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for index in 0..<count {
            try Data().write(to: dir.appendingPathComponent(String(format: "take-%03d.wav", index)))
        }
        return dir
    }

    @Test("a drop over the limit queues nothing until the user says yes")
    func largeDropAsksFirst() async throws {
        let model = makeModel()
        model.batchJobs = [BatchJob(url: Self.media("running.wav"), status: .transcribing)]
        let dir = try folder(holding: AppModel.largeDropLimit + 1)
        defer { try? FileManager.default.removeItem(at: dir) }

        await model.drop([dir], on: .queue).value

        #expect(model.pendingLargeDrop?.count == AppModel.largeDropLimit + 1)
        #expect(model.batchJobs.count == 1)

        model.confirmLargeDrop()
        await model.awaitBatchImport()

        #expect(model.pendingLargeDrop == nil)
        #expect(model.batchJobs.count == AppModel.largeDropLimit + 2)
    }

    @Test("a second large drop joins the one waiting, and one answer takes both")
    func secondLargeDropJoinsTheFirst() async throws {
        let model = makeModel()
        model.batchJobs = [BatchJob(url: Self.media("running.wav"), status: .transcribing)]
        let first = try folder(holding: AppModel.largeDropLimit + 1)
        let second = try folder(holding: AppModel.largeDropLimit + 2)
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        await model.drop([first], on: .queue).value
        await model.drop([second], on: .queue).value
        #expect(model.pendingLargeDrop?.count == 2 * AppModel.largeDropLimit + 3)

        model.confirmLargeDrop()
        await model.awaitBatchImport()

        #expect(model.batchJobs.count == 2 * AppModel.largeDropLimit + 4)
    }

    @Test("a large drop the user turns down leaves the queue as it was")
    func largeDropCancelled() async throws {
        let model = makeModel()
        model.batchJobs = [BatchJob(url: Self.media("running.wav"), status: .transcribing)]
        let dir = try folder(holding: AppModel.largeDropLimit + 1)
        defer { try? FileManager.default.removeItem(at: dir) }

        await model.drop([dir], on: .queue).value
        model.cancelLargeDrop()
        await model.awaitBatchImport()

        #expect(model.pendingLargeDrop == nil)
        #expect(model.batchJobs.map(\.url.lastPathComponent) == ["running.wav"])
    }

    @Test("a drop at the limit goes straight in, walked off the main thread")
    func dropAtTheLimitGoesStraightIn() async throws {
        let model = makeModel()
        model.batchJobs = [BatchJob(url: Self.media("running.wav"), status: .transcribing)]
        let dir = try folder(holding: AppModel.largeDropLimit)
        defer { try? FileManager.default.removeItem(at: dir) }

        let drop = model.drop([dir], on: .queue)
        #expect(model.batchJobs.count == 1, "nothing is walked before the drop returns")
        await drop.value
        await model.awaitBatchImport()

        #expect(model.pendingLargeDrop == nil)
        #expect(model.batchJobs.count == AppModel.largeDropLimit + 1)
    }

    @Test("Open With collects every file before routing them")
    func openedFilesArriveAsOneBatch() async {
        let model = makeModel()
        model.batchJobs = [BatchJob(url: Self.media("running.wav"), status: .transcribing)]

        model.collectOpenedFile(Self.media("one.wav"))
        model.collectOpenedFile(Self.media("two.wav"))
        model.collectOpenedFile(Self.media("three.wav"))
        #expect(model.pendingOpenedFiles.count == 3)

        await model.flushOpenedFiles()?.value
        await model.awaitBatchImport()

        #expect(model.batchJobs.map(\.url.lastPathComponent) == ["running.wav", "one.wav", "two.wav", "three.wav"])
        #expect(model.pendingOpenedFiles.isEmpty)
    }

    @Test("the Services pasteboard yields every file, not just the first")
    func servicesReadsEveryFile() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("DropRoutingTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([
            Self.media("one.wav") as NSURL,
            Self.media("two.wav") as NSURL,
        ])

        let urls = ServicesProvider.fileURLs(from: pasteboard)

        #expect(urls.map(\.lastPathComponent) == ["one.wav", "two.wav"])
    }
}
