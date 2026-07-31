import Foundation
import Testing
@testable import Parola
import ParolaCore

@MainActor
@Suite("AppModel batch")
struct AppModelBatchTests {

    private static func makeURL(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/AppModelBatchTests/\(name).wav")
    }

    private static func makeJob(_ name: String, status: BatchJob.Status = .pending) -> BatchJob {
        BatchJob(url: makeURL(name), status: status)
    }

    private func makeIsolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test-\(UUID())")!
    }

    private func makeModel() -> AppModel {
        AppModel(skipBootstrap: true, defaults: makeIsolatedDefaults(), libraryURL: makeTempLibraryURL("batch"))
    }

    private static func makeTranscript() -> Transcript {
        Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "hi")],
            language: "en",
            modelName: "stub"
        )
    }

    @Test("addBatchExportFormat appends new formats and ignores duplicates")
    func addBatchFormatsDeduplicates() {
        let model = makeModel()
        model.batchExportFormats = []

        model.addBatchExportFormat(.srt)
        model.addBatchExportFormat(.txt)
        model.addBatchExportFormat(.srt)

        #expect(model.batchExportFormats == [.srt, .txt])
    }

    @Test("removeBatchExportFormat strips a format from the list")
    func removeBatchFormat() {
        let model = makeModel()
        model.batchExportFormats = [.srt, .txt, .vtt]

        model.removeBatchExportFormat(.txt)

        #expect(model.batchExportFormats == [.srt, .vtt])
    }

    @Test("options(for:) falls back to global defaults when no per-format entry exists")
    func optionsFallback() {
        let model = makeModel()
        model.batchExportFormatOptionsJSON = "{}"
        model.batchExportToSourceFolder = false
        model.batchExportIncludeTimestamps = true

        let opts = model.options(for: .srt)

        #expect(opts.writeToSourceFolder == false)
        #expect(opts.includeTimestamps)
    }

    @Test("setOptions writes a per-format override that overrides the defaults")
    func setOptionsRoundTrip() {
        let model = makeModel()
        model.batchExportFormatOptionsJSON = "{}"
        model.batchExportToSourceFolder = false

        let custom = BatchExportFormatOptions(writeToSourceFolder: true, includeTimestamps: true)
        model.setOptions(custom, for: .vtt)

        let read = model.options(for: .vtt)
        #expect(read == custom)
        #expect(model.options(for: .srt).writeToSourceFolder == false)
    }

    @Test("reorderPendingBatchJobs moves only pending jobs and preserves their ids")
    func reorderPreservesIDs() {
        let model = makeModel()
        let a = Self.makeJob("a")
        let b = Self.makeJob("b")
        let c = Self.makeJob("c")
        model.batchJobs = [a, b, c]

        model.reorderPendingBatchJobs(from: IndexSet(integer: 0), to: 3)

        #expect(model.batchJobs.map(\.id) == [b.id, c.id, a.id])
    }

    @Test("reorderPendingBatchJobs keeps non-pending jobs in place")
    func reorderSkipsNonPending() {
        let model = makeModel()
        let done = Self.makeJob("done", status: .done)
        let p1 = Self.makeJob("p1")
        let p2 = Self.makeJob("p2")
        let failed = Self.makeJob("fail", status: .failed)
        model.batchJobs = [done, p1, p2, failed]

        model.reorderPendingBatchJobs(from: IndexSet(integer: 1), to: 0)

        #expect(model.batchJobs[0].id == done.id)
        #expect(model.batchJobs[3].id == failed.id)
        #expect(model.batchJobs[1].id == p2.id)
        #expect(model.batchJobs[2].id == p1.id)
    }

    @Test("moveBatchJobToTop reorders within pending slice and is a no-op for non-pending")
    func moveJobToTop() {
        let model = makeModel()
        let p1 = Self.makeJob("p1")
        let p2 = Self.makeJob("p2")
        let p3 = Self.makeJob("p3")
        model.batchJobs = [p1, p2, p3]

        model.moveBatchJobToTop(p3.id)

        #expect(model.batchJobs.map(\.id) == [p3.id, p1.id, p2.id])

        let frozen = Self.makeJob("done", status: .done)
        model.batchJobs = [frozen, p1, p2]
        model.moveBatchJobToTop(frozen.id)
        #expect(model.batchJobs.map(\.id) == [frozen.id, p1.id, p2.id])
    }

    @Test("moveBatchJob(before:) places a pending job ahead of the target")
    func moveJobBefore() {
        let model = makeModel()
        let a = Self.makeJob("a")
        let b = Self.makeJob("b")
        let c = Self.makeJob("c")
        model.batchJobs = [a, b, c]

        model.moveBatchJob(c.id, before: a.id)

        #expect(model.batchJobs.map(\.id) == [c.id, a.id, b.id])
    }

    @Test("retryBatchJob resets a failed job to pending and clears its error")
    func retryFailedJob() {
        let model = makeModel()
        let failed = BatchJob(
            url: Self.makeURL("a"),
            status: .failed,
            transcript: Self.makeTranscript(),
            error: "boom",
            progress: 0.5
        )
        model.batchJobs = [failed]

        model.retryBatchJob(failed.id)

        #expect(model.batchJobs[0].status == .pending)
        #expect(model.batchJobs[0].error == nil)
        #expect(model.batchJobs[0].progress == 0)
        #expect(model.batchJobs[0].transcript == nil)
        model.batchTask?.cancel()
        model.batchTask = nil
    }

    @Test("retrying a failed job while another is transcribing does not tear down the live batch")
    func retryDuringLiveBatchKeepsQueue() {
        let model = makeModel()
        let running = Self.makeJob("running", status: .transcribing)
        let failed = Self.makeJob("a", status: .failed)
        model.batchJobs = [running, failed]

        model.retryBatchJob(failed.id)

        #expect(model.batchJobs[0].status == .transcribing)  // live job untouched
        #expect(model.batchJobs[1].status == .pending)        // reset; the running batch's resume picks it up
        #expect(model.batchTask == nil)                       // no new queue spawned -> live batch not cancelled
        model.batchTask?.cancel()
        model.batchTask = nil
    }

    @Test("cancelBatchJob removes a non-running job from the list")
    func cancelRemovesFinishedJob() {
        let model = makeModel()
        let done = Self.makeJob("done", status: .done)
        let pending = Self.makeJob("p")
        model.batchJobs = [done, pending]
        model.selectedBatchJobID = done.id

        model.cancelBatchJob(done.id)

        #expect(model.batchJobs.map(\.id) == [pending.id])
        #expect(model.selectedBatchJobID == pending.id)
    }

    @Test("clearFinishedBatchJobs keeps pending and running jobs only")
    func clearFinishedKeepsActive() {
        let model = makeModel()
        let done = Self.makeJob("done", status: .done)
        let failed = Self.makeJob("fail", status: .failed)
        let cancelled = Self.makeJob("cancel", status: .cancelled)
        let pending = Self.makeJob("pending")
        let running = Self.makeJob("run", status: .transcribing)
        model.batchJobs = [done, failed, cancelled, pending, running]
        model.selectedBatchJobID = done.id

        model.clearFinishedBatchJobs()

        let ids = model.batchJobs.map(\.id)
        #expect(ids == [pending.id, running.id])
        #expect(model.selectedBatchJobID == pending.id)
    }

    @Test("clearBatch wipes jobs and selection")
    func clearWipesEverything() {
        let model = makeModel()
        model.batchJobs = [Self.makeJob("a"), Self.makeJob("b")]
        model.selectedBatchJobID = model.batchJobs[0].id

        model.clearBatch()

        #expect(model.batchJobs.isEmpty)
        #expect(model.selectedBatchJobID == nil)
        #expect(model.batchTask == nil)
    }

    @Test("cancelAllInFlightBatchJobs marks pending and transcribing as cancelled")
    func cancelAllInFlight() {
        let model = makeModel()
        let done = Self.makeJob("done", status: .done)
        let pending = Self.makeJob("pending")
        let running = Self.makeJob("run", status: .transcribing)
        model.batchJobs = [done, pending, running]

        model.cancelAllInFlightBatchJobs()

        #expect(model.batchJobs[0].status == .done)
        #expect(model.batchJobs[1].status == .cancelled)
        #expect(model.batchJobs[2].status == .cancelled)
    }

    @Test("batchIsRunning is true only while a job is transcribing")
    func batchIsRunningFlag() {
        let model = makeModel()
        #expect(model.batchIsRunning == false)

        model.batchJobs = [Self.makeJob("p")]
        #expect(model.batchIsRunning == false)

        model.batchJobs[0].status = .transcribing
        #expect(model.batchIsRunning)
    }

    @Test("BatchExportFormatOptions encodes and decodes through the JSON sidecar")
    func formatOptionsRoundTrip() {
        let model = makeModel()
        model.batchExportFormatOptionsJSON = "{}"

        let options: [String: BatchExportFormatOptions] = [
            "srt": BatchExportFormatOptions(writeToSourceFolder: false, includeTimestamps: true),
            "txt": BatchExportFormatOptions(writeToSourceFolder: true, includeTimestamps: false),
        ]
        model.batchExportFormatOptions = options

        let read = model.batchExportFormatOptions
        #expect(read == options)
    }

    @Test("batch exporters honor caption length, HTML theme, and per-batch timestamps")
    func batchExporterHonorsSharedOptions() {
        let srt = AppModel.batchExporter(for: .srt, includeTimestamps: false, captionLength: .short, htmlTheme: .dark)
        #expect((srt as? SrtExporter)?.options.captionLength == .short)

        let vtt = AppModel.batchExporter(for: .vtt, includeTimestamps: false, captionLength: .medium, htmlTheme: .dark)
        #expect((vtt as? VttExporter)?.options.captionLength == .medium)

        let html = AppModel.batchExporter(for: .html, includeTimestamps: true, captionLength: .none, htmlTheme: .sepia)
        #expect((html as? HtmlExporter)?.options.theme == .sepia)
        #expect((html as? HtmlExporter)?.options.showTimestamps == true)

        let md = AppModel.batchExporter(for: .md, includeTimestamps: true, captionLength: .none, htmlTheme: .light)
        #expect((md as? MarkdownExporter)?.options.showTimestamps == true)

        let txt = AppModel.batchExporter(for: .txt, includeTimestamps: true, captionLength: .none, htmlTheme: .light)
        #expect((txt as? TxtExporter)?.options.showTimestamps == true)

        let plainTxt = AppModel.batchExporter(for: .txt, includeTimestamps: false, captionLength: .none, htmlTheme: .light)
        #expect((plainTxt as? TxtExporter)?.options.showTimestamps == false)
    }

    @Test("a completed batch job is post-processed before it is stored and shown")
    func completedBatchJobIsPostProcessed() async {
        let model = makeModel()
        model.batchExportFormats = []
        model.ignoredSegmentRules = [IgnoredSegmentRule(pattern: "uh")]
        model.findReplaceRules = [FindReplaceRule(find: "acme", replace: "Acme")]
        let job = Self.makeJob("clip", status: .transcribing)
        model.batchJobs = [job]
        model.selectedBatchJobID = job.id

        let raw = Transcript(
            segments: [
                TranscriptSegment(id: 0, start: 0, end: 1, text: "uh"),
                TranscriptSegment(id: 1, start: 1, end: 2, text: "perchè acme spende un po"),
            ],
            language: "it",
            modelName: "stub"
        )
        await model.handleBatchEvent(.completed(jobID: job.id, transcript: raw))

        #expect(model.transcript?.segments.map(\.text) == ["perché Acme spende un po'"])
        #expect(model.batchJobs[0].transcript?.segments.map(\.text) == ["perché Acme spende un po'"])
        #expect(model.batchJobs[0].status == .done)
    }

    private static func makeScratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppModelBatchTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func waitForFile(at url: URL, timeout: TimeInterval = 3) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    @Test("a completed batch job runs the auto-export rules for its source")
    func completedBatchJobRunsAutoExportRules() async throws {
        let scratch = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let model = makeModel()
        model.batchExportFormats = []
        model.autoExportRules = [AutoExportRule(sourceExtensions: ["wav"], outputFormats: [.txt])]
        let source = scratch.appendingPathComponent("clip.wav")
        try Data("fake".utf8).write(to: source)
        let job = BatchJob(url: source, status: .transcribing)
        model.batchJobs = [job]

        await model.handleBatchEvent(.completed(jobID: job.id, transcript: Self.makeTranscript()))

        let written = await Self.waitForFile(at: scratch.appendingPathComponent("clip.txt"))
        #expect(written)
    }

    @Test("batch sidecars win over auto-export rules for the same target")
    func batchSidecarWinsOverAutoExportRule() async throws {
        let scratch = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let model = makeModel()
        model.batchExportFormats = [.md]
        model.setOptions(BatchExportFormatOptions(writeToSourceFolder: true, includeTimestamps: true), for: .md)
        model.markdownTimestamps = false
        model.autoExportRules = [AutoExportRule(sourceExtensions: ["wav"], outputFormats: [.md, .txt])]
        let source = scratch.appendingPathComponent("clip.wav")
        try Data("fake".utf8).write(to: source)
        let job = BatchJob(url: source, status: .transcribing)
        model.batchJobs = [job]

        await model.handleBatchEvent(.completed(jobID: job.id, transcript: Self.makeTranscript()))

        let mdURL = scratch.appendingPathComponent("clip.md")
        let mdWritten = await Self.waitForFile(at: mdURL)
        let txtWritten = await Self.waitForFile(at: scratch.appendingPathComponent("clip.txt"))
        #expect(mdWritten)
        #expect(txtWritten)
        let markdown = try String(contentsOf: mdURL, encoding: .utf8)
        #expect(markdown.contains("*["))
    }

    private static func waitForEntries(in model: AppModel, timeout: TimeInterval = 3) async -> [LibraryEntry] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let entries = await model.library.list()
            if !entries.isEmpty { return entries }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await model.library.list()
    }

    @Test("a completed batch job persists to the library titled from its source file")
    func completedBatchJobPersistsToLibrary() async throws {
        let scratch = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let model = makeModel()
        model.batchExportFormats = []
        model.selectedEntryID = "keep-me"
        let source = scratch.appendingPathComponent("interview.wav")
        try Data("fake".utf8).write(to: source)
        let job = BatchJob(url: source, status: .transcribing)
        model.batchJobs = [job]

        await model.handleBatchEvent(.completed(jobID: job.id, transcript: Self.makeTranscript()))

        let entries = await Self.waitForEntries(in: model)
        #expect(entries.count == 1)
        #expect(entries.first?.title == "interview")
        let loaded = try await model.library.load(try #require(entries.first?.id))
        #expect(loaded.document.audioURL != nil)
        #expect(model.selectedEntryID == "keep-me")
        #expect(model.batchJobs.first?.transcript != nil)
    }

    @Test("the library list refreshes once per wave finish, not per job")
    func libraryRefreshesAtWaveFinish() async throws {
        let scratch = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let model = makeModel()
        await model.libraryRefreshTask?.value
        model.batchExportFormats = []
        let source = scratch.appendingPathComponent("clip.wav")
        try Data("fake".utf8).write(to: source)
        let job = BatchJob(url: source, status: .transcribing)
        model.batchJobs = [job]

        await model.handleBatchEvent(.completed(jobID: job.id, transcript: Self.makeTranscript()))
        let persisted = await Self.waitForEntries(in: model)
        #expect(persisted.count == 1)
        #expect(model.libraryEntries.isEmpty)

        await model.handleBatchEvent(.finished)
        await model.libraryRefreshTask?.value
        #expect(model.libraryEntries.count == 1)
    }

    @Test("persisting a batch job does not re-run its auto-export rules")
    func batchPersistDoesNotRerunAutoExports() async throws {
        let scratch = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let model = makeModel()
        model.batchExportFormats = []
        model.autoExportRules = [AutoExportRule(sourceExtensions: ["wav"], outputFormats: [.txt])]
        let source = scratch.appendingPathComponent("clip.wav")
        try Data("fake".utf8).write(to: source)
        let job = BatchJob(url: source, status: .transcribing)
        model.batchJobs = [job]

        await model.handleBatchEvent(.completed(jobID: job.id, transcript: Self.makeTranscript()))

        let txt = scratch.appendingPathComponent("clip.txt")
        #expect(await Self.waitForFile(at: txt))
        _ = await Self.waitForEntries(in: model)
        try FileManager.default.removeItem(at: txt)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!FileManager.default.fileExists(atPath: txt.path))
    }

    @Test("pending, failed, and in-flight jobs survive relaunch as pending")
    func batchQueueSurvivesRelaunch() {
        let libURL = makeTempLibraryURL("batch-queue")
        let model = AppModel(skipBootstrap: true, defaults: makeIsolatedDefaults(), libraryURL: libURL)
        let pending = Self.makeJob("a")
        let failed = Self.makeJob("b", status: .failed)
        let running = Self.makeJob("c", status: .transcribing)
        let done = Self.makeJob("d", status: .done)
        model.batchJobs = [pending, failed, running, done]

        let restored = AppModel(skipBootstrap: true, defaults: makeIsolatedDefaults(), libraryURL: libURL)

        #expect(restored.batchJobs.map(\.url) == [pending.url, failed.url, running.url])
        #expect(restored.batchJobs.allSatisfy { $0.status == .pending })
        #expect(restored.batchTask == nil)
        #expect(restored.route == .batch)
    }

    @Test("the queue file is deleted when the batch clears or finishes")
    func batchQueueFileDeletedOnClear() {
        let model = makeModel()
        model.batchJobs = [Self.makeJob("a")]
        #expect(FileManager.default.fileExists(atPath: model.batchQueueFileURL.path))
        model.clearBatch()
        #expect(!FileManager.default.fileExists(atPath: model.batchQueueFileURL.path))

        model.batchJobs = [Self.makeJob("b")]
        #expect(FileManager.default.fileExists(atPath: model.batchQueueFileURL.path))
        model.batchJobs[0].status = .done
        #expect(!FileManager.default.fileExists(atPath: model.batchQueueFileURL.path))
    }

    @Test("resumePendingBatchJobs starts the queue only when idle with pending jobs")
    func resumeStartsIdlePendingQueue() {
        let model = makeModel()
        #expect(model.canResumeBatch == false)

        model.batchJobs = [Self.makeJob("a"), Self.makeJob("run", status: .transcribing)]
        #expect(model.canResumeBatch == false)

        model.batchJobs[1].status = .done
        #expect(model.canResumeBatch)

        model.resumePendingBatchJobs()
        #expect(model.batchTask != nil)
        model.batchTask?.cancel()
        model.batchTask = nil
    }

    @Test("cancelCurrentWork marks all in-flight batch jobs cancelled and returns phase to idle")
    func cancelCurrentWorkMarksBatchJobsCancelled() async {
        let model = makeModel()
        model.startBatch(urls: [URL(fileURLWithPath: "/tmp/a.wav"), URL(fileURLWithPath: "/tmp/b.wav")])
        await model.handleBatchEvent(.started(jobID: model.batchJobs[0].id))
        model.cancelCurrentWork()
        #expect(model.batchJobs.allSatisfy { $0.status == .cancelled })
        #expect(model.phase == .idle)
    }

    @Test("cancelCurrentWork with a loaded transcript and nothing in flight leaves phase .ready")
    func cancelCurrentWorkWithReadyPhaseAndNoWorkKeepsReady() {
        let model = makeModel()
        model.transcript = Self.makeTranscript()
        model.phase = .ready

        model.cancelCurrentWork()

        #expect(model.phase == .ready)
    }

    @Test("batch job selection clears the loaded library entry")
    func selectBatchJobClearsSelectedEntry() async {
        let model = makeModel()
        model.startBatch(urls: [URL(fileURLWithPath: "/tmp/a.wav")])
        let jobID = model.batchJobs[0].id
        await model.handleBatchEvent(.started(jobID: jobID))
        let t = Transcript(segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "t")], language: "en", modelName: "m")
        await model.handleBatchEvent(.completed(jobID: jobID, transcript: t))

        model.selectedEntryID = "stale-entry"
        model.selectBatchJob(jobID)
        #expect(model.selectedEntryID == nil)

        model.selectedEntryID = "stale-entry"
        model.openBatchJobTranscript(jobID)
        #expect(model.selectedEntryID == nil)
    }

    private static func installStaleArtifacts(on model: AppModel) {
        model.promptOutput = AppModel.PromptOutput(promptName: "p", text: "stale")
        model.actionItems = [ActionItem(task: "stale task")]
        model.smartChapters = [Chapter(title: "stale chapter", start: 0)]
    }

    private static func expectArtifactsCleared(on model: AppModel) {
        #expect(model.promptOutput == nil)
        #expect(model.actionItems.isEmpty)
        #expect(model.smartChapters.isEmpty)
    }

    @Test("selecting a batch job clears artifacts derived from the previous transcript")
    func selectBatchJobClearsDerivedArtifacts() async {
        let model = makeModel()
        model.startBatch(urls: [URL(fileURLWithPath: "/tmp/a.wav")])
        let jobID = model.batchJobs[0].id
        await model.handleBatchEvent(.started(jobID: jobID))
        await model.handleBatchEvent(.completed(jobID: jobID, transcript: Self.makeTranscript()))

        Self.installStaleArtifacts(on: model)
        model.selectBatchJob(jobID)
        Self.expectArtifactsCleared(on: model)

        Self.installStaleArtifacts(on: model)
        model.openBatchJobTranscript(jobID)
        Self.expectArtifactsCleared(on: model)
    }

    @Test("a finished streaming recording persists its captured audio for playback")
    func streamingFinishPersistsCapturedAudio() async throws {
        let scratch = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let model = makeModel()
        let wav = scratch.appendingPathComponent("capture.wav")
        try Data("fake".utf8).write(to: wav)
        let final = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "t")],
            language: "en",
            modelName: "m",
            sourceURL: wav
        )

        await model.handleStreamingEvent(.finished(final))

        #expect(model.sourceFileURL == wav)
        let entries = await Self.waitForEntries(in: model)
        #expect(entries.count == 1)
        let loaded = try await model.library.load(try #require(entries.first?.id))
        #expect(loaded.document.audioURL != nil)
    }

    @Test("a finished recording clears artifacts derived from the previous transcript")
    func streamingFinishClearsDerivedArtifacts() async {
        let model = makeModel()
        Self.installStaleArtifacts(on: model)

        await model.handleStreamingEvent(.finished(Self.makeTranscript()))

        Self.expectArtifactsCleared(on: model)
    }

    @Test("arrivals during recording defer instead of stomping capture")
    func recordingDefersArrivals() {
        let model = makeModel()
        model.phase = .recording(source: .microphone)
        let url = URL(fileURLWithPath: "/tmp/arrival.wav")
        model.transcribe(fileURL: url)
        #expect(model.deferredArrivals == [url])
        #expect(model.phase == .recording(source: .microphone))
        #expect(model.batchJobs.isEmpty)

        model.startBatch(urls: [URL(fileURLWithPath: "/tmp/b.wav")])
        #expect(model.deferredArrivals.count == 2)
        #expect(model.batchJobs.isEmpty)
    }

    @Test("watched-folder arrivals defer while a file transcription is running")
    func watchedArrivalDefersDuringFileTranscription() {
        let model = makeModel()
        model.fileTranscribeTask = Task {}
        let url = URL(fileURLWithPath: "/tmp/watched.wav")

        model.handleWatchedArrival(url)

        #expect(model.deferredArrivals == [url])
        model.fileTranscribeTask?.cancel()
        model.fileTranscribeTask = nil
    }

    @Test("startBatch defers while a single-file transcription is running")
    func startBatchDefersDuringFileTranscription() {
        let model = makeModel()
        let running = AppModel.Phase.transcribing(file: URL(fileURLWithPath: "/tmp/single.wav"))
        model.phase = running
        model.fileTranscribeTask = Task {}
        let url = URL(fileURLWithPath: "/tmp/queued.wav")

        model.startBatch(urls: [url])

        #expect(model.deferredArrivals == [url])
        #expect(model.batchJobs.isEmpty)
        #expect(model.batchTask == nil)
        #expect(model.phase == running)
        model.fileTranscribeTask?.cancel()
        model.fileTranscribeTask = nil
    }

    @Test("a batch deferred behind a single-file run starts when that run drains")
    func deferredBatchStartsAfterFileTranscription() {
        let model = makeModel()
        model.fileTranscribeTask = Task {}
        let url = URL(fileURLWithPath: "/tmp/queued.wav")
        model.startBatch(urls: [url])
        #expect(model.batchJobs.isEmpty)

        model.fileTranscribeTask?.cancel()
        model.fileTranscribeTask = nil
        model.transcript = Self.makeTranscript()
        model.phase = .ready
        model.drainDeferredArrivals()

        #expect(model.deferredArrivals.isEmpty)
        #expect(model.batchJobs.map(\.url) == [url])
        model.clearBatch()
    }

    @Test("arrivals during a subtitle burn defer instead of racing the export")
    func exportingDefersArrivals() {
        let model = makeModel()
        model.phase = .exporting(progress: 0.3)
        let url = URL(fileURLWithPath: "/tmp/arrival.wav")
        model.transcribe(fileURL: url)
        #expect(model.deferredArrivals == [url])
        #expect(model.phase == .exporting(progress: 0.3))
        #expect(model.batchJobs.isEmpty)

        model.startBatch(urls: [URL(fileURLWithPath: "/tmp/b.wav")])
        #expect(model.deferredArrivals.count == 2)
        #expect(model.batchJobs.isEmpty)
    }

    @Test("only recording and exporting defer arrivals")
    func phaseDeferralMatrix() {
        let model = makeModel()
        model.phase = .recording(source: .microphone)
        #expect(model.phaseDefersArrivals)
        model.phase = .exporting(progress: 0.5)
        #expect(model.phaseDefersArrivals)

        let passThrough: [AppModel.Phase] = [
            .idle, .ready, .failed(message: "x"),
            .loadingModel(name: "m"),
            .downloadingModel(name: "m", progress: 0),
            .transcribing(file: URL(fileURLWithPath: "/tmp/t.wav")),
        ]
        for phase in passThrough {
            model.phase = phase
            #expect(!model.phaseDefersArrivals)
        }
    }

    @Test("deferred arrivals drain into the batch when recording finishes")
    func deferredArrivalsDrainOnFinish() async {
        let model = makeModel()
        model.phase = .recording(source: .microphone)
        let url = URL(fileURLWithPath: "/tmp/arrival.wav")
        model.transcribe(fileURL: url)
        let final = Transcript(segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "t")], language: "en", modelName: "m")
        await model.handleStreamingEvent(.finished(final))
        #expect(model.deferredArrivals.isEmpty)
        #expect(model.batchJobs.contains { $0.url == url })
    }

    @Test("cancelling discards deferred arrivals")
    func cancelDiscardsDeferredArrivals() {
        let model = makeModel()
        model.phase = .recording(source: .microphone)
        model.transcribe(fileURL: URL(fileURLWithPath: "/tmp/arrival.wav"))
        model.cancelCurrentWork()
        #expect(model.deferredArrivals.isEmpty)
        #expect(model.batchJobs.isEmpty)
    }

    @Test("single-file arrivals during a running batch join the queue")
    func runningBatchAbsorbsSingleArrival() async {
        let model = makeModel()
        model.startBatch(urls: [URL(fileURLWithPath: "/tmp/a.wav")])
        await model.handleBatchEvent(.started(jobID: model.batchJobs[0].id))
        let url = URL(fileURLWithPath: "/tmp/late.wav")
        model.transcribe(fileURL: url)
        #expect(model.batchJobs.contains { $0.url == url && $0.status == .pending })
        #expect(model.deferredArrivals.isEmpty)
    }

    @Test(".parola drop during recording defers instead of opening")
    func parolaDropDuringRecordingDefers() {
        let model = makeModel()
        model.transcript = Transcript(segments: [], language: "en", modelName: "m")
        model.phase = .recording(source: .microphone)
        let url = URL(fileURLWithPath: "/tmp/arrival.parola")
        model.transcribe(fileURL: url)
        #expect(model.deferredArrivals == [url])
        #expect(model.phase == .recording(source: .microphone))
        #expect(model.transcript?.segments.isEmpty == true)
    }

    @Test(".parola arrivals drain separately from audio arrivals")
    func parolaArrivalsDrainSeparately() async {
        let model = makeModel()
        model.phase = .recording(source: .microphone)
        let audio = URL(fileURLWithPath: "/tmp/audio.wav")
        let parola = URL(fileURLWithPath: "/tmp/doc.parola")
        model.transcribe(fileURL: audio)
        model.transcribe(fileURL: parola)
        #expect(model.deferredArrivals == [audio, parola])
        let final = Transcript(segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "t")], language: "en", modelName: "m")
        await model.handleStreamingEvent(.finished(final))
        #expect(model.deferredArrivals.isEmpty)
        #expect(model.batchJobs.contains { $0.url == audio })
        #expect(!model.batchJobs.contains { $0.url == parola })
    }
}
