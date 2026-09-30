import Foundation
import Testing
@testable import Parola

/// Toolbar search fields and menu titles can't be read back in a unit test, so the per-page wiring is pinned in the sources.
@MainActor
@Suite("Toolbar search per page")
struct ToolbarSearchTests {
    private func source(_ name: String) throws -> String {
        let path = #filePath.replacingOccurrences(
            of: "ParolaAppTests/ToolbarSearchTests.swift",
            with: "ParolaApp/\(name).swift"
        )
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    @Test("each page's search is named for the page, and Statistics has none")
    func titles() {
        #expect(AppModel.Route.transcript.searchTitle() == "Search Library")
        #expect(AppModel.Route.queue.searchTitle() == "Search Queue")
        #expect(AppModel.Route.batch.searchTitle() == "Search Batch")
        #expect(AppModel.Route.recentlyDeleted.searchTitle() == "Search Recently Deleted")
        #expect(AppModel.Route.statistics.searchTitle() == nil)
    }

    @Test("the page names read in Italian")
    func italianTitles() throws {
        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        let italian = try #require(Bundle(path: path))
        #expect(AppModel.Route.transcript.searchTitle(bundle: italian) == "Cerca nella libreria")
        #expect(AppModel.Route.queue.searchTitle(bundle: italian) == "Cerca nella coda")
        #expect(AppModel.Route.batch.searchTitle(bundle: italian) == "Cerca nel batch")
        #expect(AppModel.Route.recentlyDeleted.searchTitle(bundle: italian) == "Cerca in Eliminati di recente")
    }

    @Test(
        "each page's field is the toolbar's, named by its own route",
        arguments: [
            ("Views/ContentRoutes", ".transcript"),
            ("Views/QueueView", ".queue"),
            ("Views/BatchView", ".batch"),
            ("Views/MacRecentlyDeletedView", ".recentlyDeleted"),
        ]
    )
    func pageField(file: String, route: String) throws {
        let page = try source(file)
        #expect(page.contains(".toolbarSearch(text: "))
        #expect(page.contains("for: \(route))"))
    }

    @Test(
        "no page keeps a second field of its own",
        arguments: ["Views/QueueView", "Views/BatchJobList", "Views/RecentlyDeletedHeader"]
    )
    func noInlineField(file: String) throws {
        let page = try source(file)
        #expect(!page.contains("SearchPill("))
    }

    @Test("Statistics has no search field")
    func statisticsHasNone() throws {
        let page = try source("Views/StatisticsView")
        #expect(!page.contains(".toolbarSearch(") && !page.contains(".searchable("))
    }

    @Test("Edit ▸ Search takes the current page's name, and stands down where there is none")
    func editMenuFollowsThePage() throws {
        let commands = try source("Views/AppCommands").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(commands.contains("let searchTitle = model.route.searchTitle()"))
        #expect(commands.contains(#"Button(searchTitle ?? String(localized: "Search Library")) { model.focusLibrarySearch() }"#))
        #expect(commands.contains(".disabled(model.introduction.isPresented || searchTitle == nil)"))
    }
}
