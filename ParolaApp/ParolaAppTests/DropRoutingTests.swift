import AppKit
import Foundation
import Testing
@testable import Parola
import ParolaCore

@MainActor
@Suite("Split drop routing")
struct DropRoutingTests {

    private func makeModel(features: Set<ParolaFeature> = Set(ParolaFeature.allCases)) -> AppModel {
        AppModel(
            skipBootstrap: true,
            defaults: UserDefaults(suiteName: "test-\(UUID())")!,
            libraryURL: makeTempLibraryURL("drop"),
            features: features
        )
    }

    private static func media(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/DropRoutingTests/\(name)")
    }

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

    @Test("a drop while recording goes to the deferred pile rather than stomping the take")
    func dropWhileRecordingDefers() {
        let model = makeModel()
        model.phase = .recording(source: .microphone)

        model.transcribeNow(urls: [Self.media("arrival.wav")])

        #expect(model.deferredArrivals.map(\.lastPathComponent) == ["arrival.wav"])
        #expect(model.phase == .recording(source: .microphone))
    }

    @Test("the Transcribe Now half joins a running batch instead of racing it")
    func transcribeNowJoinsARunningBatch() {
        let model = makeModel()
        model.batchJobs = [BatchJob(url: Self.media("running.wav"), status: .transcribing)]

        model.transcribeNow(urls: [Self.media("late.wav")])

        #expect(model.route == .batch)
        #expect(model.batchJobs.map(\.url.lastPathComponent) == ["running.wav", "late.wav"])
        #expect(model.deferredArrivals.isEmpty)
    }

    @Test("the Add to Queue half appends to the queue and shows it")
    func addToQueueAppends() {
        let model = makeModel()
        model.batchJobs = [BatchJob(url: Self.media("running.wav"), status: .transcribing)]

        model.addToQueue(urls: [Self.media("a.wav"), Self.media("b.wav")])

        #expect(model.route == .batch)
        #expect(model.batchJobs.map(\.url.lastPathComponent) == ["running.wav", "a.wav", "b.wav"])
    }

    @Test("the Add to Queue half never lands a gated build on a failure pane")
    func addToQueueFallsBackWithoutBatch() {
        let model = makeModel(features: [.youtube])
        model.phase = .recording(source: .microphone)

        model.addToQueue(urls: [Self.media("a.wav"), Self.media("b.wav")])

        #expect(model.batchJobs.isEmpty)
        #expect(model.deferredArrivals.count == 2)
        #expect(model.phase == .recording(source: .microphone))
    }

    @Test("a dropped folder of mkv files reaches the queue")
    func folderOfMkvReachesTheQueue() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DropRoutingTests-mkv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appendingPathComponent("one.mkv"))
        try Data().write(to: dir.appendingPathComponent("two.mkv"))
        let model = makeModel()
        model.batchJobs = [BatchJob(url: Self.media("running.wav"), status: .transcribing)]

        model.addToQueue(urls: [dir])

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

    @Test("two dropped projects open one instead of becoming batch jobs")
    func projectsNeverBecomeBatchJobs() {
        let model = makeModel()

        model.transcribeNow(urls: [Self.media("a.parola"), Self.media("b.parola")])

        #expect(model.batchJobs.isEmpty)
        #expect(model.deferredArrivals.isEmpty)
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

        model.phase = .recording(source: .microphone)
        #expect(model.dropZonePlan == .queueOnly(count: 2))
    }

    @Test("Open With collects every file before routing them")
    func openedFilesArriveAsOneBatch() {
        let model = makeModel()
        model.batchJobs = [BatchJob(url: Self.media("running.wav"), status: .transcribing)]

        model.collectOpenedFile(Self.media("one.wav"))
        model.collectOpenedFile(Self.media("two.wav"))
        model.collectOpenedFile(Self.media("three.wav"))
        #expect(model.pendingOpenedFiles.count == 3)

        model.flushOpenedFiles()

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
