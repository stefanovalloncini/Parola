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
        model.libraryBrowsingAll = true
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
        #expect(await settled(hosted) { tables(hosted).count == 2 })
        #expect(tables(hosted).first === browse)
        #expect(browse.numberOfRows == rows)
        search(Array(ids.prefix(12)), in: hosted.model)
        _ = await settled(hosted)
        #expect(browse.numberOfRows == rows)

        search(nil, in: hosted.model)
        #expect(await settled(hosted) { tables(hosted).count == 1 })
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
        // One unheadered section row above the results.
        let firstPage = LibrarySearchResults.pageSize + 1
        #expect(await settled(hosted) { tables(hosted).last?.numberOfRows == firstPage })
        let results = try #require(tables(hosted).last)

        results.scrollRowToVisible(results.numberOfRows - 1)
        #expect(await settled(hosted) { results.numberOfRows == firstPage + LibrarySearchResults.pageSize })

        hosted.model.searchRanking = Array(ids.dropFirst())
        _ = await settled(hosted)
        #expect(results.numberOfRows == firstPage + LibrarySearchResults.pageSize, "the same query re-ranked keeps its pages")

        hosted.model.searchQuery = "tak"
        hosted.model.searchRanking = ids.reversed()
        #expect(await settled(hosted) { tables(hosted).last?.numberOfRows == firstPage })
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
        #expect(await settled(hosted) {
            let responder = window.firstResponder
            return responder is NSTableView && responder !== browse
        })

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
        #expect(await settled(hosted) { window.firstResponder === browse })
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

    @Test("a row within a lead's distance of the end asks for the next page while more results wait")
    func nextPageNearTheEnd() {
        let page = LibrarySearchResults.pageSize
        let lead = LibrarySearchResults.pageLead
        #expect(LibrarySearchResults.wantsNextPage(appearedAt: page - lead, shown: page, total: 130))
        #expect(LibrarySearchResults.wantsNextPage(appearedAt: page - 1, shown: page, total: 130))
        #expect(!LibrarySearchResults.wantsNextPage(appearedAt: page - lead - 1, shown: page, total: 130))
        #expect(!LibrarySearchResults.wantsNextPage(appearedAt: page - 1, shown: page, total: page))
    }
}
