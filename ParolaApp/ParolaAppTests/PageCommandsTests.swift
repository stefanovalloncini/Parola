import AppKit
import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport
import SwiftUI

@MainActor
@Suite("Menus follow the page in front")
struct PageCommandsTests {
    let model: AppModel

    init() {
        model = AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("pagecommands"))
    }

    private func openTranscript() {
        model.transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "Hello world.")],
            language: "en",
            modelName: "tiny"
        )
        model.phase = .ready
        model.route = .transcript
    }

    @Test("⌘F puts the caret in the library's search field when no transcript is in front")
    func findSearchesTheLibrary() {
        let before = model.librarySearchFocusRequests

        #expect(model.findCommandEnabled)
        model.beginFind()

        #expect(model.librarySearchFocusRequests == before &+ 1)
        #expect(!model.findIsOpen)
    }

    @Test("⌘F searches the Queue while a transcript waits behind it, and is off where no page searches")
    func findFollowsTheRoute() {
        openTranscript()
        model.openQueue()
        let before = model.librarySearchFocusRequests

        #expect(model.findCommandEnabled)
        model.beginFind()
        #expect(model.librarySearchFocusRequests == before &+ 1)
        #expect(!model.findIsOpen)

        model.route = .statistics
        #expect(!model.findCommandEnabled)
    }

    @Test("⌘F finds in the transcript on screen, and in the results laid over it searches instead")
    func findInTheTranscriptOnlyWhenItShows() {
        openTranscript()
        let before = model.librarySearchFocusRequests

        model.beginFind()
        #expect(model.findIsOpen)
        #expect(model.librarySearchFocusRequests == before)

        model.toggleFind()
        model.searchRanking = []
        model.beginFind()
        #expect(!model.findIsOpen)
        #expect(model.librarySearchFocusRequests == before &+ 1)
    }

    @Test("⌘P, ⌘E, ⌘1–3 and ⇧⌘I wait for a transcript on screen: not on the Queue or results over it")
    func transcriptCommandsNeedTheTranscriptInFront() {
        openTranscript()
        #expect(model.mainTranscriptCommandsEnabled)
        #expect(model.canShow(.transcript))

        model.openQueue()
        #expect(model.hasTranscript, "the Queue keeps the transcript loaded behind it")
        #expect(!model.mainTranscriptCommandsEnabled)
        #expect(!model.canShow(.transcript))

        model.route = .transcript
        model.searchRanking = []
        #expect(!model.mainTranscriptCommandsEnabled)
        #expect(!model.canShow(.transcript))

        model.searchRanking = nil
        #expect(model.mainTranscriptCommandsEnabled)
    }

    @Test("a mode set while another page is in front still lands for when the transcript comes back")
    func paneModeSetsBehindAnotherPage() {
        openTranscript()
        model.transcriptPaneMode = .summary
        model.openQueue()

        model.setTranscriptPaneMode(.transcript)

        #expect(model.transcriptPaneMode == .transcript)
    }

    private func viewMenu() async -> NSMenu? {
        await waitUntil { NSApp.mainMenu?.items.first { $0.title == "View" }?.submenu != nil }
        return NSApp.mainMenu?.items.first { $0.title == "View" }?.submenu
    }

    @Test("View ▸ Go reaches every sidebar page and Statistics on ⌥⌘1–7, and View shows or hides the sidebar")
    func goSectionInTheViewMenu() async throws {
        let view = try #require(await viewMenu())
        let titles = view.items.map(\.title)
        let go = try #require(titles.firstIndex(of: "Go"))
        let pages = ["Library", "Transcriptions", "Meetings", "Dictations", "Queue", "Recently Deleted", "Statistics"]

        for (offset, page) in pages.enumerated() {
            let item = view.items[go + 1 + offset]
            #expect(item.title == page)
            #expect(item.keyEquivalent == String(offset + 1))
            #expect(item.keyEquivalentModifierMask == [.command, .option])
        }
        let sidebar = titles.contains("Show Sidebar") || titles.contains("Hide Sidebar")
        #expect(sidebar)
    }

    private func goItem(_ title: String) -> NSMenuItem? {
        let menu = NSHostingMenu(rootView: GoCommands(model: model))
        menu.update()
        return menu.items.first { $0.title == title }
    }

    @Test("Go ▸ Queue is on only while the sidebar has a Queue row")
    func activityFollowsTheSidebarRow() {
        let library = goItem("Library")
        let idle = goItem("Queue")
        #expect(!model.sidebarShowsActivity)
        #expect(library?.isEnabled == true)
        #expect(idle?.isEnabled == false)

        model.batchJobs = [BatchJob(url: URL(fileURLWithPath: "/tmp/PageCommandsTests/a.wav"), status: .pending)]
        let waiting = goItem("Queue")
        #expect(model.sidebarShowsActivity)
        #expect(waiting?.isEnabled == true)
    }

    private static func source(_ name: String) throws -> String {
        let path = #filePath.replacingOccurrences(
            of: "ParolaAppTests/PageCommandsTests.swift",
            with: "ParolaApp/\(name).swift"
        )
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    @Test("View ▸ Sort By and Show set the library's own sort, grouping and date filter")
    func libraryListMenusDriveTheModel() {
        model.librarySortOrder = .newest
        let menus = PageListMenus.library(model)
        #expect(menus.sort.selected == LibrarySortOrder.newest.rawValue)
        #expect(menus.sort.options.map(\.id) == LibrarySortOrder.allCases.map(\.rawValue))
        #expect(menus.groupsByDateApplies)

        menus.sort.choose(LibrarySortOrder.oldest.rawValue)
        menus.show?.choose(LibraryDateRangeFilter.week.rawValue)
        menus.groupsByDate?.wrappedValue = false

        #expect(model.librarySortOrder == .oldest)
        #expect(model.dateRangeFilter == .week)
        #expect(!model.libraryGroupsByDate)
        model.librarySortOrder = .titleAZ
        #expect(!PageListMenus.library(model).groupsByDateApplies)
    }

    @Test("Recently Deleted and the Queue hand their header's sort, and Recently Deleted its kind, to the View menu")
    func pageStateMenusWriteThroughTheirBindings() {
        var deletedSort = RecentlyDeletedSort.deletedEarliest
        var kind = RecentlyDeletedCategoryFilter.all
        var queueSort = QueueView.SortOption.newestFirst
        let deleted = PageListMenus.recentlyDeleted(
            sort: Binding(get: { deletedSort }, set: { deletedSort = $0 }),
            kind: Binding(get: { kind }, set: { kind = $0 })
        )
        let queue = PageListMenus.queue(sort: Binding(get: { queueSort }, set: { queueSort = $0 }))

        deleted.sort.choose(RecentlyDeletedSort.titleAZ.rawValue)
        deleted.show?.choose(RecentlyDeletedCategoryFilter.meetings.rawValue)
        queue.sort.choose(QueueView.SortOption.mostProgress.rawValue)

        #expect(deletedSort == .titleAZ)
        #expect(kind == .meetings)
        #expect(queueSort == .mostProgress)
        #expect(queue.show == nil)
    }

    @Test("View holds Sort By and Show ahead of Go, and each list page publishes its own")
    func sortAndShowInTheViewMenu() async throws {
        let view = try #require(await viewMenu())
        let titles = view.items.map(\.title)
        let sort = try #require(titles.firstIndex(of: "Sort By"))
        let show = try #require(titles.firstIndex(of: "Show"))
        let go = try #require(titles.firstIndex(of: "Go"))
        #expect(sort < show && show < go)

        let library = try Self.source("Views/LibraryListView")
        let deleted = try Self.source("Views/MacRecentlyDeletedView")
        let queue = try Self.source("Views/QueueView")
        #expect(library.contains(".background { LibraryListMenusPublisher(listShows: pageCount > 0) }"))
        #expect(deleted.contains(".focusedSceneValue(\\.pageListMenus, .recentlyDeleted(sort: $sortOption, kind: $categoryFilter))"))
        #expect(queue.contains(".focusedSceneValue(\\.pageListMenus, .queue(sort: $sortOption))"))
    }
}
