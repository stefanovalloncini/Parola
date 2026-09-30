import AppKit
import Foundation
import SwiftUI
import Testing
import ParolaCore
@testable import Parola
import ParolaTestSupport

@MainActor
@Suite("Search results sit over the browse list", .serialized)
struct LibrarySearchListTests {
    private static let baseDate = Date(timeIntervalSince1970: 1_750_000_000)

    private struct Hosted {
        let model: AppModel
        let host: NSHostingView<AnyView>
        let window: NSWindow
    }

    private func entries(_ count: Int) -> [LibraryEntry] {
        (0..<count).map { index in
            let manifest = ParolaDocument.Manifest(
                createdAt: Self.baseDate.addingTimeInterval(-Double(index) * 8 * 3600),
                originalAudioName: "take-\(index).m4a",
                title: "Take \(index)",
                modelName: "stub",
                language: "en"
            )
            let id = String(format: "%04d-list", index)
            return LibraryEntry(
                id: id,
                bundleURL: URL(fileURLWithPath: "/tmp/LibrarySearchListTests/\(id).parola"),
                manifest: manifest
            )
        }
    }

    /// Ordered in, far off screen: AppKit only runs the key view loop for a window that is up.
    private func host(_ count: Int) async -> Hosted {
        let model = AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("search-list"))
        await model.libraryRefreshTask?.value
        model.libraryEntries = entries(count)
        model.route = .transcript
        let host = NSHostingView(rootView: AnyView(ContentRoutes().environment(model)))
        let window = NSWindow(
            contentRect: NSRect(x: -12_000, y: -12_000, width: 900, height: 760),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.orderFront(nil)
        let hosted = Hosted(model: model, host: host, window: window)
        _ = await settled(hosted) { !tables(hosted).isEmpty }
        return hosted
    }

    private func close(_ hosted: Hosted) {
        hosted.window.orderOut(nil)
        hosted.window.contentView = nil
    }

    private func tables(_ hosted: Hosted) -> [NSTableView] {
        func walk(_ view: NSView) -> [NSTableView] {
            if let table = view as? NSTableView { return [table] }
            return view.subviews.flatMap(walk)
        }
        return walk(hosted.host)
    }

    /// Focus lands a run loop turn after the responder moves, so conditions are polled rather than read once.
    private func settled(_ hosted: Hosted, until condition: (() -> Bool)? = nil) async -> Bool {
        for _ in 0..<(condition == nil ? 6 : 60) {
            hosted.host.layoutSubtreeIfNeeded()
            hosted.window.displayIfNeeded()
            if condition?() == true { return true }
            try? await Task.sleep(for: .milliseconds(15))
        }
        return condition?() ?? true
    }

    private func search(_ ids: [LibraryEntry.ID]?, in model: AppModel) {
        model.searchQuery = ids == nil ? "" : "take"
        model.searchMatches = Dictionary(uniqueKeysWithValues: (ids ?? []).map {
            ($0, LibrarySearchIndex.Match(entryID: $0, score: 1, matchCount: 1, snippet: "take"))
        })
        model.searchRanking = ids
    }

    @Test("a query leaves the browse list's table, rows and scroll where they were")
    func queryLeavesTheBrowseList() async throws {
        let hosted = await host(40)
        defer { close(hosted) }
        let browse = try #require(tables(hosted).first)
        let rows = browse.numberOfRows
        browse.scrollRowToVisible(rows - 1)
        _ = await settled(hosted)
        let scrolled = browse.visibleRect.origin

        let ids = hosted.model.libraryEntries.map(\.id)
        search([ids[3], ids[1], ids[2]], in: hosted.model)
        let tablesWait = await settled(hosted) { tables(hosted).count == 2 }
        #expect(tablesWait)
        #expect(tables(hosted).first === browse)
        #expect(browse.numberOfRows == rows)
        search(Array(ids.prefix(12)), in: hosted.model)
        _ = await settled(hosted)
        #expect(browse.numberOfRows == rows)

        search(nil, in: hosted.model)
        let tablesWait2 = await settled(hosted) { tables(hosted).count == 1 }
        #expect(tablesWait2)
        #expect(tables(hosted).first === browse)
        #expect(browse.numberOfRows == rows)
        #expect(browse.visibleRect.origin == scrolled)
    }

    @Test("results come a page at a time, and the next page lands as the end scrolls into view")
    func resultsArePaged() async throws {
        let hosted = await host(130)
        defer { close(hosted) }
        let ids = hosted.model.libraryEntries.map(\.id)
        search(ids, in: hosted.model)
        let firstPage = LibrarySearchResults.pageSize
        let tablesWait = await settled(hosted) { tables(hosted).last?.numberOfRows == firstPage }
        #expect(tablesWait)
        let results = try #require(tables(hosted).last)

        results.scrollRowToVisible(results.numberOfRows - 1)
        let numberOfRowsWait = await settled(hosted) { results.numberOfRows == firstPage + LibrarySearchResults.pageSize }
        #expect(numberOfRowsWait)

        hosted.model.searchRanking = Array(ids.dropFirst())
        _ = await settled(hosted)
        #expect(results.numberOfRows == firstPage + LibrarySearchResults.pageSize, "the same query re-ranked keeps its pages")

        hosted.model.searchQuery = "tak"
        hosted.model.searchRanking = ids.reversed()
        let tablesWait2 = await settled(hosted) { tables(hosted).last?.numberOfRows == firstPage }
        #expect(tablesWait2)
    }

    @Test("a new query opens its results at the top, so it neither lands mid-list nor fetches a second page at once")
    func newQueryOpensAtTheTop() async throws {
        let hosted = await host(130)
        defer { close(hosted) }
        let ids = hosted.model.libraryEntries.map(\.id)
        search(ids, in: hosted.model)
        #expect(await settled(hosted) { tables(hosted).last?.numberOfRows == LibrarySearchResults.pageSize })
        let results = try #require(tables(hosted).last)
        results.scrollRowToVisible(results.numberOfRows - 1)
        #expect(await settled(hosted) { results.numberOfRows == 2 * LibrarySearchResults.pageSize })
        let deep = results.rows(in: results.visibleRect).location
        #expect(deep > 0)

        hosted.model.searchQuery = "tak"
        hosted.model.searchRanking = ids.reversed()
        let atTop = await settled(hosted) {
            guard let table = tables(hosted).last else { return false }
            return table.rows(in: table.visibleRect).location == 0
        }
        #expect(atTop, "the new results open at row \(results.rows(in: results.visibleRect).location)")
        #expect(results.numberOfRows == LibrarySearchResults.pageSize)
    }

    @Test("the keyboard follows the list on screen, and Tab passes over the covered one")
    func keyboardFollowsTheListOnScreen() async throws {
        let hosted = await host(20)
        defer { close(hosted) }
        let window = hosted.window
        let browse = try #require(tables(hosted).first)
        window.makeFirstResponder(browse)
        _ = await settled(hosted)

        let ids = hosted.model.libraryEntries.map(\.id)
        search(Array(ids.prefix(3)), in: hosted.model)
        let responderWait = await settled(hosted) {
            let responder = window.firstResponder
            return responder is NSTableView && responder !== browse
        }
        #expect(responderWait)

        window.makeFirstResponder(nil)
        for _ in 0..<4 {
            window.selectNextKeyView(nil)
            _ = await settled(hosted)
            #expect(window.firstResponder !== browse)
        }
        for _ in 0..<4 {
            window.selectPreviousKeyView(nil)
            _ = await settled(hosted)
            #expect(window.firstResponder !== browse)
        }

        window.makeFirstResponder(tables(hosted).last)
        _ = await settled(hosted)
        search(nil, in: hosted.model)
        let firstResponderWait = await settled(hosted) { window.firstResponder === browse }
        #expect(firstResponderWait)
    }

    @Test("a click on a results page with nothing in it never reaches the list under it")
    func emptyResultsTakeTheClick() async throws {
        let hosted = await host(20)
        defer { close(hosted) }
        let browse = try #require(tables(hosted).first)
        search([], in: hosted.model)
        _ = await settled(hosted)

        let hit = hosted.host.hitTest(NSPoint(x: 450, y: 300))
        var view = hit
        while let current = view {
            #expect(current !== browse.enclosingScrollView)
            view = current.superview
        }
    }

    /// What the Edit menu does with a key window: the first responder in the chain that takes the action runs it.
    private func sendToFirstResponder(_ action: Selector, in window: NSWindow) {
        var responder = window.firstResponder
        while let current = responder {
            if current.responds(to: action) {
                current.perform(action, with: nil)
                return
            }
            responder = current.nextResponder
        }
    }

    @Test("Select All in the results takes every hit, not just the pages realised so far")
    func selectAllTakesEveryResult() async throws {
        let hosted = await host(130)
        defer { close(hosted) }
        let ids = hosted.model.libraryEntries.map(\.id)
        search(ids, in: hosted.model)
        let tablesWait = await settled(hosted) { tables(hosted).last?.numberOfRows == LibrarySearchResults.pageSize }
        #expect(tablesWait)
        let results = try #require(tables(hosted).last)
        hosted.window.makeFirstResponder(results)
        _ = await settled(hosted)

        sendToFirstResponder(#selector(NSResponder.selectAll(_:)), in: hosted.window)
        _ = await settled(hosted)
        // The table highlights rows as they are realised, so the pages past the first are scrolled in to check them.
        for _ in 0..<4 {
            results.scrollRowToVisible(results.numberOfRows - 1)
            _ = await settled(hosted)
        }
        #expect(results.numberOfRows == ids.count)
        #expect(results.selectedRowIndexes.contains(results.numberOfRows - 1))
    }

    @Test("Select All counts entries, not the date titles the table also highlights")
    func selectAllCountsEntries() {
        let displays = entries(7).map { LibraryRowDisplay(entry: $0) }
        let items = LibraryListItem.items(for: LibraryDateGroups.groups(for: displays, sortOrder: .newest, now: Self.baseDate))
        let highlighted = Set(items.map(\.id))
        #expect(highlighted.count > displays.count, "the titles are rows with ids of their own")
        #expect(LibraryListItem.entries(in: highlighted, items: items) == Set(displays.map(\.id)))
    }

    @Test("only a selection of every realised row, with more results waiting, stands for all of them")
    func everyRealisedRowStandsForAll() {
        let realised = ["a", "b", "c"]
        #expect(LibrarySearchResults.reachesEveryResult(["a", "b", "c"], realised: realised, total: 10))
        #expect(!LibrarySearchResults.reachesEveryResult(["a", "b"], realised: realised, total: 10))
        #expect(!LibrarySearchResults.reachesEveryResult(["a", "b", "c"], realised: realised, total: 3))
        #expect(!LibrarySearchResults.reachesEveryResult(["a"], realised: ["a"], total: 10))
    }

    @Test("a row within a lead's distance of the end asks for the next page while more results wait")
    func nextPageNearTheEnd() {
        let page = LibrarySearchResults.pageSize
        let lead = LibrarySearchResults.pageLead
        #expect(LibrarySearchResults.wantsNextPage(appearedAt: page - lead, shown: page, total: 130))
        #expect(LibrarySearchResults.wantsNextPage(appearedAt: page - 1, shown: page, total: 130))
        #expect(!LibrarySearchResults.wantsNextPage(appearedAt: page - lead - 1, shown: page, total: 130))
        #expect(!LibrarySearchResults.wantsNextPage(appearedAt: page - 1, shown: page, total: page))
    }

    @Test("a row whose notes change is no longer equal to the one on screen, so it redraws with the new count")
    func noteChangeRedrawsTheRow() {
        let entry = entries(1)[0]
        var noted = entry.manifest
        noted.segmentNotes = ["0": "check the figure"]
        let withNote = LibraryEntry(id: entry.id, bundleURL: entry.bundleURL, manifest: noted)
        let before = LibraryRowDisplay(entry: entry)
        let after = LibraryRowDisplay(entry: withNote)
        #expect(before.noteCount == 0)
        #expect(after.noteCount == 1)
        #expect(before != after)

        func row(_ display: LibraryRowDisplay) -> LibraryListRow {
            LibraryListRow(row: display, detail: .excerpt, isSelected: false, rename: { _ in })
        }
        #expect(row(before) != row(after))
        #expect(row(before) == row(LibraryRowDisplay(entry: entry)))

        var moved = entry.manifest
        moved.category = .meeting
        #expect(before != LibraryRowDisplay(entry: LibraryEntry(id: entry.id, bundleURL: entry.bundleURL, manifest: moved)))
    }
}
