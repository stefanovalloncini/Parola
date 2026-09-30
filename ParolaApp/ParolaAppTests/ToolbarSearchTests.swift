import Foundation
import Testing
@testable import Parola

/// Toolbar search fields can't be rendered in a unit test, so the per-page wiring is pinned in the sources.
@MainActor
@Suite("Toolbar search per page")
struct ToolbarSearchTests {
    private func source(_ name: String) throws -> String {
        let path = #filePath.replacingOccurrences(
            of: "ParolaAppTests/ToolbarSearchTests.swift",
            with: "ParolaApp/Views/\(name).swift"
        )
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    @Test("every page but Statistics has a field, so Search Library has somewhere to put the caret")
    func pagesWithAField() {
        for route in AppModel.Route.allCases {
            #expect(ContentRoutes.hasSearchField(route) == (route != .statistics), "\(route)")
        }
    }

    @Test(
        "each page's field is the toolbar's, named for the page",
        arguments: [
            ("ContentRoutes", "Search Library"),
            ("QueueView", "Search Queue"),
            ("BatchView", "Search Batch"),
            ("MacRecentlyDeletedView", "Search Recently Deleted"),
        ]
    )
    func pageField(file: String, prompt: String) throws {
        let page = try source(file)
        #expect(page.contains(".toolbarSearch(text: "))
        #expect(page.contains(#"prompt: "\#(prompt)")"#))
    }

    @Test("no page keeps a second field of its own", arguments: ["QueueView", "BatchJobList", "RecentlyDeletedHeader"])
    func noInlineField(file: String) throws {
        let page = try source(file)
        #expect(!page.contains("SearchPill("))
    }

    @Test("Statistics has no search field")
    func statisticsHasNone() throws {
        let page = try source("StatisticsView")
        #expect(!page.contains(".toolbarSearch(") && !page.contains(".searchable("))
    }

    @Test("the page prompts read in Italian")
    func italianPrompts() throws {
        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        let italian = try #require(Bundle(path: path))
        #expect(String(localized: "Search Library", bundle: italian) == "Cerca nella libreria")
        #expect(String(localized: "Search Queue", bundle: italian) == "Cerca nella coda")
        #expect(String(localized: "Search Batch", bundle: italian) == "Cerca nel batch")
        #expect(String(localized: "Search Recently Deleted", bundle: italian) == "Cerca in Eliminati di recente")
    }
}
