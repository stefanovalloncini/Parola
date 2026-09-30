import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

extension TranscriberMockSuites {
    @MainActor
    @Suite("Batch routing", .serialized)
    struct BatchRoutingTests {
        private func makeModel() -> AppModel {
            let model = AppModel(bootstrap: AppBootstrap(
                mode: .test, library: makeTempLibraryURL("batch-routing"), defaultsOverride: temporaryDefaults(),
                sideEffects: [], filePicker: TestFilePicker(), clock: ContinuousClock(),
                enabledFeaturesOverride: Set(ParolaFeature.allCases)
            ))
            model.batchExportPresetIDs = []
            model.generatesCardMetadata = false
            return model
        }

        private static func job(_ name: String, _ status: BatchJob.Status = .pending) -> BatchJob {
            BatchJob(url: URL(fileURLWithPath: "/tmp/BatchRoutingTests/\(name).m4a"), status: status)
        }

        private static func transcript(_ text: String) -> Transcript {
            Transcript(segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: text)], language: "en", modelName: "stub")
        }

        private func sidebar(_ model: AppModel) -> SidebarItem? {
            SidebarSelection.current(model.sidebarPage, sidebarPeople: [], showsActivity: model.sidebarShowsActivity)
        }

        private func seedEntry(in model: AppModel, text: String) async throws -> LibraryEntry {
            let seed = LibraryStore(libraryURL: model.library.libraryURL, extraIndexer: nil)
            return try await seed.add(transcript: Self.transcript(text), audioSource: nil)
        }

        private func open(_ entry: LibraryEntry, in model: AppModel) async -> Bool {
            model.loadEntry(entry.id)
            return await waitUntil { model.selectedEntryID == entry.id && model.transcript != nil }
        }

        @Test(
            "finished jobs still listed leave the Library page usable",
            arguments: [BatchJob.Status.done, .failed, .cancelled, .pending]
        )
        func finishedJobsDontBlock(status: BatchJob.Status) {
            let model = makeModel()
            model.batchJobs = [BatchJob(url: URL(fileURLWithPath: "/tmp/a.m4a"), status: status)]
            model.goHome()
            #expect(model.route == .transcript)
            #expect(model.isBrowsingLibrary)
            #expect(model.isBrowsingWholeLibrary)
            #expect(ContentRoutes.routeID(for: model) == .library)
            #expect(sidebar(model) == .library)
        }

        @Test("starting a batch shows it under Activity")
        func startingShowsActivity() async throws {
            try await withMocksCleared(.transcriber) {
                await installMockTranscriber(segments: [(start: 0, end: 1, text: "queued")], gate: MockTranscriberGate())
                let model = makeModel()
                let file = try tempWAV("batch-routing-start")
                defer { try? FileManager.default.removeItem(at: file) }

                model.startBatch(urls: [file])

                #expect(model.route == .queue)
                #expect(sidebar(model) == .activity)
                model.cancelAllInFlightBatchJobs()
            }
        }

        @Test("adding files to a batch, running or finished, shows the queue")
        func addingShowsActivity() async throws {
            try await withMocksCleared(.transcriber) {
                await installMockTranscriber(segments: [(start: 0, end: 1, text: "added")], gate: MockTranscriberGate())
                let running = makeModel()
                running.batchJobs = [Self.job("running", .transcribing)]
                running.addBatchFiles([URL(fileURLWithPath: "/tmp/BatchRoutingTests/late.m4a")])
                #expect(running.batchJobs.count == 2)
                #expect(running.route == .queue)

                let finished = makeModel()
                finished.batchJobs = [Self.job("finished", .done)]
                let file = try tempWAV("batch-routing-add")
                defer { try? FileManager.default.removeItem(at: file) }
                finished.addBatchFiles([file])
                #expect(finished.batchJobs.count == 2)
                #expect(finished.route == .queue)
                finished.cancelAllInFlightBatchJobs()
            }
        }

        @Test("files added to a listed batch show the queue while they are checked")
        func checkingShowsTheQueue() async throws {
            try await withMocksCleared(.transcriber) {
                await installMockTranscriber(segments: [(start: 0, end: 1, text: "checked")], gate: MockTranscriberGate())
                let model = makeModel()
                model.batchJobs = [Self.job("finished", .done)]
                let file = try tempWAV("batch-routing-check")
                defer { try? FileManager.default.removeItem(at: file) }

                model.importBatchFiles([file])
                #expect(model.batchCheckingNotice != nil)
                #expect(model.route == .queue)

                await model.awaitBatchImport()
                #expect(model.batchJobs.count == 2)
                model.cancelAllInFlightBatchJobs()
            }
        }

        @Test("files parked behind a run join the batch without leaving the page they landed on", arguments: [false, true])
        func drainStaysOnThePage(batchListed: Bool) async throws {
            try await withMocksCleared(.transcriber) {
                await installMockTranscriber(segments: [(start: 0, end: 1, text: "drained")], gate: MockTranscriberGate())
                let model = makeModel()
                let entry = try await seedEntry(in: model, text: "the transcript that just landed")
                let opened = await open(entry, in: model)
                #expect(opened)
                if batchListed { model.batchJobs = [Self.job("finished", .done)] }
                let file = try tempWAV("batch-routing-drain")
                defer { try? FileManager.default.removeItem(at: file) }
                model.deferredArrivals = [file]

                model.drainDeferredArrivals()
                await model.awaitBatchImport()

                let joined = model.batchJobs.last?.url
                #expect(joined == file)
                #expect(model.route == .transcript)
                #expect(model.selectedEntryID == entry.id)
                #expect(model.sidebarShowsActivity)
                model.cancelAllInFlightBatchJobs()
            }
        }

        @Test("a batch that grows while a take records leaves the take on screen")
        func takeKeepsTheScreen() async {
            let model = makeModel()
            model.batchJobs = [Self.job("running", .transcribing)]
            model.installTestTake(source: .microphone)
            let route = model.route

            model.addBatchFiles([URL(fileURLWithPath: "/tmp/BatchRoutingTests/late.m4a")])
            model.transcribeNow(urls: [URL(fileURLWithPath: "/tmp/BatchRoutingTests/now.m4a")])
            model.addToQueue(urls: [URL(fileURLWithPath: "/tmp/BatchRoutingTests/queued.m4a")])
            await model.awaitBatchImport()

            #expect(model.batchJobs.map(\.url.lastPathComponent) == ["running.m4a", "late.m4a", "now.m4a", "queued.m4a"])
            #expect(model.route == route)
        }

        @Test("a running job leaves the Library page on screen")
        func runningJobLeavesTheLibrary() async {
            let model = makeModel()
            let job = Self.job("running")
            model.batchJobs = [job]
            await model.handleBatchEvent(.started(jobID: job.id))
            #expect(model.phase == .transcribing(file: job.url))

            model.goHome()

            #expect(model.transcriptRoutePhase == .ready)
            #expect(model.isBrowsingLibrary)
            #expect(ContentRoutes.routeID(for: model) == .library)
            #expect(sidebar(model) == .library)
        }

        @Test("the New menu stays available while a batch runs, and waits for a file's own run")
        func newMenuDuringARun() async {
            let model = makeModel()
            let job = Self.job("running")
            model.batchJobs = [job]
            await model.handleBatchEvent(.started(jobID: job.id))
            #expect(!ContentToolbar.isBusy(for: model))

            model.phase = .transcribing(file: URL(fileURLWithPath: "/tmp/BatchRoutingTests/single.m4a"))
            #expect(ContentToolbar.isBusy(for: model))
        }

        @Test("a running job keeps the pane under it, and a file's own run gets its own")
        func phaseViewDuringARun() async throws {
            let model = makeModel()
            let entry = try await seedEntry(in: model, text: "open while the batch runs")
            let opened = await open(entry, in: model)
            #expect(opened)
            let readyPane = ContentRoutes.phaseViewID(for: model)
            let job = Self.job("running")
            model.batchJobs = [job]

            await model.handleBatchEvent(.started(jobID: job.id))
            #expect(ContentRoutes.routeID(for: model) == .phase)
            #expect(ContentRoutes.phaseViewID(for: model) == readyPane)

            model.goHome()
            await model.awaitTranscriptClose()
            #expect(ContentRoutes.routeID(for: model) == .library)

            model.phase = .transcribing(file: URL(fileURLWithPath: "/tmp/BatchRoutingTests/single.m4a"))
            #expect(ContentRoutes.routeID(for: model) == .phase)
            #expect(ContentRoutes.phaseViewID(for: model) != readyPane)
        }

        @Test("the queue page shows the import check instead of its empty state")
        func queueShowsTheCheck() {
            let model = makeModel()
            model.batchFilesBeingChecked = 2
            #expect(!QueueView.showsEmptyState(for: model))
            #expect(Self.draws(NSProgressIndicator.self, in: model))

            model.batchFilesBeingChecked = 0
            #expect(QueueView.showsEmptyState(for: model))
            #expect(!Self.draws(NSProgressIndicator.self, in: model))
        }

        private static func draws(_ type: NSView.Type, in model: AppModel) -> Bool {
            let host = NSHostingView(rootView: QueueView().environment(model))
            host.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
            host.layoutSubtreeIfNeeded()
            var found = false
            func walk(_ view: NSView) {
                for sub in view.subviews {
                    if sub.isKind(of: type) { found = true }
                    walk(sub)
                }
            }
            walk(host)
            return found
        }

        @Test("a file's own run shows its pane, even a file a finished batch ran")
        func singleFileRunKeepsItsPane() async {
            let model = makeModel()
            let job = Self.job("again")
            model.batchJobs = [job]
            await model.handleBatchEvent(.started(jobID: job.id))
            await model.handleBatchEvent(.failed(jobID: job.id, reason: "boom"))
            await model.handleBatchEvent(.finished)

            model.phase = .transcribing(file: job.url)

            #expect(model.transcriptRoutePhase == .transcribing(file: job.url))
            #expect(!model.isBrowsingLibrary)
        }

        @Test("an open transcript stays open while a job runs, and the Library row still closes it")
        func openTranscriptDuringARun() async throws {
            let model = makeModel()
            let entry = try await seedEntry(in: model, text: "read while the batch runs")
            let opened = await open(entry, in: model)
            #expect(opened)
            let job = Self.job("running")
            model.batchJobs = [job]

            await model.handleBatchEvent(.started(jobID: job.id))
            #expect(model.transcriptRoutePhase == .ready)
            #expect(model.transcript?.segments.first?.text == "read while the batch runs")
            #expect(model.canReturnToOrigin)

            model.goHome()
            await model.awaitTranscriptClose()

            #expect(model.transcript == nil)
            #expect(model.isBrowsingLibrary)
        }

        enum StopRun: CaseIterable {
            case cancelBatch
            case clear
            case cancelJob
        }

        @Test("stopping a run short hands back the phase its job painted", arguments: StopRun.allCases)
        func stoppingHandsThePhaseBack(stop: StopRun) async {
            let model = makeModel()
            let job = Self.job("running")
            model.batchJobs = [job]
            await model.handleBatchEvent(.started(jobID: job.id))

            switch stop {
            case .cancelBatch: model.cancelAllInFlightBatchJobs()
            case .clear: model.clearBatch()
            case .cancelJob: model.cancelBatchJob(job.id)
            }

            #expect(model.phase == .idle)
            model.goHome()
            #expect(model.isBrowsingLibrary)
        }

        @Test("cancelling the running job while a take records leaves the take's pane")
        func cancellingAJobKeepsTheTake() {
            let model = makeModel()
            let running = Self.job("running", .transcribing)
            model.batchJobs = [running]
            model.installTestTake(source: .microphone)
            let phase = model.phase
            let route = model.route

            model.cancelBatchJob(running.id)

            #expect(model.batchJobs.first?.status == .cancelled)
            #expect(model.phase == phase)
            #expect(model.route == route)
        }

        @Test("a job that finishes while an entry is open leaves the entry on screen")
        func finishedJobLeavesTheOpenEntry() async throws {
            let model = makeModel()
            let entry = try await seedEntry(in: model, text: "the entry the user opened")
            let opened = await open(entry, in: model)
            #expect(opened)
            let source = try tempWAV("batch-routing-finished")
            defer { try? FileManager.default.removeItem(at: source) }
            let job = BatchJob(url: source)
            model.batchJobs = [job]
            model.selectedBatchJobID = job.id

            await model.handleBatchEvent(.started(jobID: job.id))
            await model.handleBatchEvent(.completed(jobID: job.id, transcript: Self.transcript("the batch job")))
            let landed = await waitUntil { model.batchJobs.first?.entryID != nil }
            #expect(landed)
            await model.handleBatchEvent(.finished)

            #expect(model.selectedEntryID == entry.id)
            #expect(model.transcript?.segments.first?.text == "the entry the user opened")
        }

        @Test("a job that finishes while the queue shows leaves the loaded entry alone")
        func finishedJobLeavesTheLoadedEntry() async throws {
            let model = makeModel()
            let entry = try await seedEntry(in: model, text: "the entry the user loaded")
            let opened = await open(entry, in: model)
            #expect(opened)
            let source = try tempWAV("batch-routing-queue")
            defer { try? FileManager.default.removeItem(at: source) }
            let job = BatchJob(url: source)
            model.batchJobs = [job]
            model.selectedBatchJobID = job.id
            model.openQueue()

            await model.handleBatchEvent(.started(jobID: job.id))
            await model.handleBatchEvent(.completed(jobID: job.id, transcript: Self.transcript("the batch job")))
            let landed = await waitUntil { model.batchJobs.first?.entryID != nil }
            #expect(landed)
            await model.handleBatchEvent(.finished)

            #expect(model.selectedEntryID == entry.id)
            #expect(model.transcript?.segments.first?.text == "the entry the user loaded")
        }

        @Test("clicking a job row marks it and leaves what is loaded alone")
        func selectingAJobLeavesTheLoadedEntry() async throws {
            let model = makeModel()
            let entry = try await seedEntry(in: model, text: "the entry the user loaded")
            let opened = await open(entry, in: model)
            #expect(opened)
            let done = BatchJob(
                url: URL(fileURLWithPath: "/tmp/BatchRoutingTests/done.m4a"), status: .done,
                transcript: Self.transcript("the finished job")
            )
            model.batchJobs = [done]
            model.route = .batch

            model.selectBatchJob(done.id)

            #expect(model.selectedBatchJobID == done.id)
            #expect(model.selectedEntryID == entry.id)
            #expect(model.transcript?.segments.first?.text == "the entry the user loaded")
            #expect(model.route == .batch)
        }

        @Test("opening a finished job shows its transcript on the Library route")
        func openingAJobShowsIt() async throws {
            let model = makeModel()
            let entry = try await seedEntry(in: model, text: "the job's entry")
            let done = BatchJob(url: URL(fileURLWithPath: "/tmp/BatchRoutingTests/saved.m4a"), status: .done, entryID: entry.id)
            model.batchJobs = [done]
            model.openQueue()

            let opening = model.openBatchJobTranscript(done.id)
            let transcript = try await opening?.value

            #expect(transcript?.segments.first?.text == "the job's entry")
            #expect(model.route == .transcript)
            #expect(model.selectedEntryID == entry.id)
            #expect(model.selectedBatchJobID == done.id)
        }

        @Test("a job that finishes over the Library page leaves the list up")
        func finishedJobLeavesTheLibrary() async throws {
            let model = makeModel()
            let source = try tempWAV("batch-routing-library")
            defer { try? FileManager.default.removeItem(at: source) }
            let job = BatchJob(url: source)
            model.batchJobs = [job]
            model.selectedBatchJobID = job.id
            model.goHome()

            await model.handleBatchEvent(.started(jobID: job.id))
            await model.handleBatchEvent(.completed(jobID: job.id, transcript: Self.transcript("the batch job")))
            let landed = await waitUntil { model.batchJobs.first?.entryID != nil }
            #expect(landed)
            await model.handleBatchEvent(.finished)

            #expect(model.transcript == nil)
            #expect(model.isBrowsingLibrary)
        }
    }
}
