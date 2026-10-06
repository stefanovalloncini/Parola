import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Queue rows as a list")
struct QueueListTests {

    private func makeModel() -> AppModel {
        AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("queue-list"))
    }

    private static func job(_ name: String, _ status: BatchJob.Status) -> BatchJob {
        BatchJob(url: URL(fileURLWithPath: "/tmp/QueueListTests/\(name).wav"), status: status)
    }

    private func menu(_ jobs: [BatchJob], in model: AppModel, cancelAll: @escaping () -> Void = {}) -> NSMenu {
        let menu = NSHostingMenu(rootView: QueueRowMenu(model: model, ids: Set(jobs.map(\.id)), cancelAll: cancelAll))
        menu.update()
        return menu
    }

    private func titles(_ menu: NSMenu) -> [String] {
        menu.items.map { $0.isSeparatorItem ? "|" : $0.title }
    }

    @Test("a running row offers Cancel for itself, and Cancel All… only asks")
    func cancelAllAsksFirst() throws {
        let model = makeModel()
        let running = Self.job("running", .transcribing)
        let failed = Self.job("failed", .failed)
        model.batchJobs = [running, failed]
        var asked = false
        let rowMenu = menu([running], in: model) { asked = true }

        #expect(titles(rowMenu) == ["Cancel", "|", "Cancel All…"])
        let cancelAll = try #require(rowMenu.items.firstIndex { $0.title == "Cancel All…" })
        rowMenu.performActionForItem(at: cancelAll)
        #expect(asked)
        #expect(model.batchJobs.map(\.status) == [.transcribing, .failed])

        let cancel = try #require(rowMenu.items.firstIndex { $0.title == "Cancel" })
        rowMenu.performActionForItem(at: cancel)
        #expect(model.batchJobs.map(\.status) == [.cancelled, .failed])
    }

    @Test("a waiting row's menu says Remove, as its ✕ does, and a running row's says Cancel")
    func waitingRowsSayRemove() throws {
        let model = makeModel()
        let running = Self.job("running", .transcribing)
        let waiting = Self.job("waiting", .pending)
        let next = Self.job("next", .pending)
        model.batchJobs = [running, waiting, next]

        #expect(titles(menu([waiting], in: model)) == ["Remove", "|", "Cancel All…"])
        #expect(titles(menu([running, waiting], in: model)) == ["Remove", "Cancel", "|", "Cancel All…"])
        #expect(JobCancelAction.oneJob(status: .pending).help == "Remove")

        let rowMenu = menu([waiting], in: model)
        let remove = try #require(rowMenu.items.firstIndex { $0.title == "Remove" })
        rowMenu.performActionForItem(at: remove)
        #expect(model.batchJobs.map(\.id) == [running.id, next.id])
    }

    @Test("the menu acts on every selected row, and Open waits for a single one")
    func menuFollowsTheSelection() {
        let model = makeModel()
        let done = Self.job("done", .done)
        let otherDone = Self.job("other", .done)
        let failed = Self.job("failed", .failed)
        model.batchJobs = [done, otherDone, failed]

        #expect(titles(menu([done], in: model)) == ["Open", "Reveal in Finder"])
        #expect(titles(menu([done, otherDone, failed], in: model)) == ["Reveal in Finder", "Retry"])
    }

    @Test("Delete on finished rows takes them off the list; on a running one it cancels it")
    func deleteRemovesOrCancels() {
        let model = makeModel()
        let running = Self.job("running", .transcribing)
        let done = Self.job("done", .done)
        let failed = Self.job("failed", .failed)
        let cancelled = Self.job("cancelled", .cancelled)
        let kept = Self.job("kept", .done)
        model.batchJobs = [running, done, failed, cancelled, kept]

        model.deleteBatchJobs([running.id, done.id, failed.id, cancelled.id])

        #expect(model.batchJobs.map(\.id) == [running.id, kept.id])
        #expect(model.batchJobs.map(\.status) == [.cancelled, .done])
    }

    @Test("Retry on several rows puts them all back in line")
    func retryEverySelectedRow() {
        let model = makeModel()
        let running = Self.job("running", .transcribing)
        let failed = Self.job("failed", .failed)
        let cancelled = Self.job("cancelled", .cancelled)
        model.batchJobs = [running, failed, cancelled]

        model.retryBatchJobs([failed.id, cancelled.id])

        #expect(model.batchJobs.map(\.status) == [.transcribing, .pending, .pending])
    }

    @Test("VoiceOver finds the Queue's title and its sections as headings")
    func queueHeadings() async {
        let model = makeModel()
        model.batchJobs = [Self.job("a", .transcribing), Self.job("b", .failed)]
        let page = HostedWindow(QueueView().environment(model), width: 900, height: 600)
        defer { page.close() }
        _ = await waitUntil { page.rowCount >= 2 }

        let headings = HostedAccessibility.elements(in: page.host)
            .filter { $0.role == "AXHeading" }
            .compactMap { $0.name?.lowercased() }

        for title in ["queue", "in progress", "failed"] {
            #expect(headings.contains(title), "\(title) in \(headings)")
        }
    }

    @Test("the Queue is a native list: arrow keys and several rows at once")
    func queueIsAList() async throws {
        let model = makeModel()
        model.batchJobs = [Self.job("a", .transcribing), Self.job("b", .failed), Self.job("c", .done)]
        let page = HostedWindow(QueueView().environment(model), width: 900, height: 600)
        defer { page.close() }

        let realised = await waitUntil { page.rowCount >= 3 }

        #expect(realised)
        let table = try #require(page.table)
        #expect(table.allowsMultipleSelection)
    }
}

extension TranscriberMockSuites {
    @MainActor
    @Suite("Queue run", .serialized)
    struct QueueRunTests {

        private func makeModel() -> AppModel {
            let model = AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("queue-run"))
            model.batchExportPresetIDs = []
            model.generatesCardMetadata = false
            return model
        }

        private func makeWAV(_ label: String) throws -> URL {
            let sampleRate = 16_000, bytesPerSample = 2
            let dataBytes = Int(Double(sampleRate) * 0.3) * bytesPerSample
            var data = Data()
            func ascii(_ s: String) { data.append(contentsOf: Array(s.utf8)) }
            func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
            func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
            ascii("RIFF"); le32(UInt32(36 + dataBytes)); ascii("WAVE")
            ascii("fmt "); le32(16); le16(1); le16(1)
            le32(UInt32(sampleRate)); le32(UInt32(sampleRate * bytesPerSample))
            le16(UInt16(bytesPerSample)); le16(UInt16(bytesPerSample * 8))
            ascii("data"); le32(UInt32(dataBytes))
            data.append(Data(count: dataBytes))
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("parola-queue-run-\(label)-\(UUID().uuidString).wav")
            try data.write(to: url)
            return url
        }

        private func installMock(gate: MockTranscriberGate, log: MockTranscriberLog) async {
            await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "queued words")], gate: gate, log: log
            ))
        }

        @Test("a waiting job taken off the Queue is never transcribed, and the one behind it still is", .timeLimit(.minutes(1)))
        func removedWaitingJobNeverRuns() async throws {
            try await withMocksCleared(.transcriber) {
                let gate = MockTranscriberGate()
                let log = MockTranscriberLog()
                defer { Task { await gate.open() } }
                await installMock(gate: gate, log: log)
                let model = makeModel()
                let files = try ["first", "second", "third"].map(makeWAV)
                defer { for file in files { try? FileManager.default.removeItem(at: file) } }

                model.startBatch(urls: files)
                model.deleteBatchJobs([model.batchJobs[1].id])
                await gate.open()

                let drained = await waitUntil { model.batchTask == nil && model.batchJobs.allSatisfy { $0.status == .done } }
                let asked = await log.urls.map(\.lastPathComponent)
                #expect(drained)
                #expect(asked == [files[0].lastPathComponent, files[2].lastPathComponent])
                #expect(model.batchJobs.map(\.url) == [files[0], files[2]])
                model.clearBatch()
            }
        }

        @Test("a job gone by the time its start arrives stops the run there, and the jobs still waiting go on", .timeLimit(.minutes(1)))
        func jobGoneAtItsStartLetsTheRestRun() async throws {
            try await withMocksCleared(.transcriber) {
                let gate = MockTranscriberGate()
                let log = MockTranscriberLog()
                defer { Task { await gate.open() } }
                await installMock(gate: gate, log: log)
                let model = makeModel()
                let waiting = try makeWAV("waiting")
                defer { try? FileManager.default.removeItem(at: waiting) }
                model.batchJobs = [BatchJob(url: waiting)]

                await model.handleBatchEvent(.started(jobID: UUID()))

                #expect(model.batchPhaseFile == nil)
                let resumed = await waitUntil {
                    guard model.batchJobs.first?.status == .transcribing else { return false }
                    return await !log.urls.isEmpty
                }
                let asked = await log.urls
                #expect(resumed)
                #expect(asked == [waiting])
                await gate.open()
                let drained = await waitUntil { model.batchTask == nil }
                #expect(drained)
                #expect(model.batchJobs.map(\.status) == [.done])
                model.clearBatch()
            }
        }
    }
}
