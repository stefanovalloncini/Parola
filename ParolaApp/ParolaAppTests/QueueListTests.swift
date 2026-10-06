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
