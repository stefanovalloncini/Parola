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

    @Test("a completed batch job is post-processed before it is stored and shown")
    func completedBatchJobIsPostProcessed() {
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
        model.handleBatchEvent(.completed(jobID: job.id, transcript: raw))

        #expect(model.transcript?.segments.map(\.text) == ["perché Acme spende un po'"])
        #expect(model.batchJobs[0].transcript?.segments.map(\.text) == ["perché Acme spende un po'"])
        #expect(model.batchJobs[0].status == .done)
    }

    @Test("cancelCurrentWork marks all in-flight batch jobs cancelled and returns phase to idle")
    func cancelCurrentWorkMarksBatchJobsCancelled() {
        let model = makeModel()
        model.startBatch(urls: [URL(fileURLWithPath: "/tmp/a.wav"), URL(fileURLWithPath: "/tmp/b.wav")])
        model.handleBatchEvent(.started(jobID: model.batchJobs[0].id))
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
    func selectBatchJobClearsSelectedEntry() {
        let model = makeModel()
        model.startBatch(urls: [URL(fileURLWithPath: "/tmp/a.wav")])
        let jobID = model.batchJobs[0].id
        model.handleBatchEvent(.started(jobID: jobID))
        let t = Transcript(segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "t")], language: "en", modelName: "m")
        model.handleBatchEvent(.completed(jobID: jobID, transcript: t))

        model.selectedEntryID = "stale-entry"
        model.selectBatchJob(jobID)
        #expect(model.selectedEntryID == nil)

        model.selectedEntryID = "stale-entry"
        model.openBatchJobTranscript(jobID)
        #expect(model.selectedEntryID == nil)
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

    @Test("deferred arrivals drain into the batch when recording finishes")
    func deferredArrivalsDrainOnFinish() {
        let model = makeModel()
        model.phase = .recording(source: .microphone)
        let url = URL(fileURLWithPath: "/tmp/arrival.wav")
        model.transcribe(fileURL: url)
        let final = Transcript(segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "t")], language: "en", modelName: "m")
        model.handleStreamingEvent(.finished(final))
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
    func runningBatchAbsorbsSingleArrival() {
        let model = makeModel()
        model.startBatch(urls: [URL(fileURLWithPath: "/tmp/a.wav")])
        model.handleBatchEvent(.started(jobID: model.batchJobs[0].id))
        let url = URL(fileURLWithPath: "/tmp/late.wav")
        model.transcribe(fileURL: url)
        #expect(model.batchJobs.contains { $0.url == url && $0.status == .pending })
        #expect(model.deferredArrivals.isEmpty)
    }
}
