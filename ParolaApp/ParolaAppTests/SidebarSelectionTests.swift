import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@Suite("Sidebar selection")
struct SidebarSelectionTests {
    private let giulia = UUID()

    private func page(
        route: AppModel.Route = .transcript, listShowing: Bool = true, searching: Bool = false,
        filter: EntryCategory? = nil, person: UUID? = nil
    ) -> SidebarSelection.Page {
        .init(route: route, listShowing: listShowing, searching: searching, libraryFilter: filter, personFilter: person)
    }

    @Test("the library list highlights Library, a category or a person")
    func listPages() {
        #expect(SidebarSelection.current(page(), sidebarPeople: [], showsActivity: false) == .library)
        #expect(SidebarSelection.current(page(filter: .meeting), sidebarPeople: [], showsActivity: false) == .category(.meeting))
        #expect(SidebarSelection.current(page(person: giulia), sidebarPeople: [giulia], showsActivity: false) == .person(giulia))
    }

    @Test("a person without a sidebar row highlights nothing")
    func hiddenPerson() {
        #expect(SidebarSelection.current(page(person: giulia), sidebarPeople: [], showsActivity: false) == nil)
    }

    @Test("a person picked in the header narrows the category, which keeps its row lit")
    func personNarrowingACategory() {
        let narrowed = page(filter: .meeting, person: giulia)
        #expect(SidebarSelection.current(narrowed, sidebarPeople: [giulia], showsActivity: false) == .category(.meeting))
    }

    @Test("an open transcript, a progress page or search results leave every row clickable")
    func nothingHighlighted() {
        #expect(SidebarSelection.current(page(listShowing: false), sidebarPeople: [], showsActivity: false) == nil)
        #expect(SidebarSelection.current(page(searching: true), sidebarPeople: [], showsActivity: false) == nil)
        #expect(SidebarSelection.current(page(route: .statistics), sidebarPeople: [], showsActivity: false) == nil)
        #expect(SidebarSelection.current(page(route: .recording), sidebarPeople: [], showsActivity: false) == nil)
        #expect(SidebarSelection.place(of: page(route: .recording)) == nil)
    }

    @Test("Recently Deleted and Activity own their pages")
    func ownPages() {
        #expect(SidebarSelection.current(page(route: .recentlyDeleted), sidebarPeople: [], showsActivity: false) == .recentlyDeleted)
        #expect(SidebarSelection.current(page(route: .queue), sidebarPeople: [], showsActivity: true) == .activity)
        #expect(SidebarSelection.current(page(route: .batch), sidebarPeople: [], showsActivity: false) == nil)
    }

    @Test("the page's destination counts a person or the queue the sidebar has no row for")
    func destinations() {
        #expect(SidebarSelection.destination(of: page(person: giulia)) == .person(giulia))
        #expect(SidebarSelection.destination(of: page(route: .queue)) == .activity)
        #expect(SidebarSelection.current(page(route: .queue), sidebarPeople: [], showsActivity: false) == nil)
        #expect(SidebarSelection.destination(of: page(listShowing: false, person: giulia)) == nil)
    }

    @Test("the user's place stays put under a transcript, a progress pane or results")
    func places() {
        #expect(SidebarSelection.place(of: page(listShowing: false, filter: .meeting)) == .category(.meeting))
        #expect(SidebarSelection.place(of: page(searching: true, person: giulia)) == .person(giulia))
        #expect(SidebarSelection.place(of: page(listShowing: false)) == .library)
        #expect(SidebarSelection.place(of: page(route: .statistics)) == nil)
    }

    @Test("Activity counts the jobs still to run, then the ones that failed in the last day")
    func activity() {
        let file = URL(fileURLWithPath: "/tmp/a.m4a")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let pending = BatchJob(url: file, status: .pending)
        let running = BatchJob(url: file, status: .transcribing)
        let failed = BatchJob(url: file, status: .failed)
        let oldFailure = BatchJob(url: file, status: .failed)
        let failedAt = [failed.id: now.addingTimeInterval(-3600), oldFailure.id: now.addingTimeInterval(-25 * 3600)]
        func activity(_ jobs: [BatchJob]) -> SidebarActivity? {
            SidebarActivity.current(jobs: jobs, failedAt: failedAt, now: now)
        }

        #expect(activity([]) == nil)
        #expect(activity([pending]) == .inProgress(count: 1))
        #expect(activity([pending, running, failed]) == .inProgress(count: 2), "work still to run outranks a failure")
        #expect(activity([failed, oldFailure]) == .failed(count: 1), "a failure older than a day no longer counts")
        #expect(activity([oldFailure]) == nil)
        #expect(activity([BatchJob(url: file, status: .done), BatchJob(url: file, status: .cancelled)]) == nil)
        #expect(activity([BatchJob(url: file, status: .failed)]) == .failed(count: 1), "a failure with no time on record is a new one")
        #expect(SidebarActivity.nextExpiry(failedAt: failedAt, now: now) == now.addingTimeInterval(23 * 3600))
    }

    @Test("the Activity row reads In Progress or Failed, in Italian too")
    func activityTitles() throws {
        #expect(SidebarActivity.inProgress(count: 3).title == "In Progress")
        #expect(SidebarActivity.failed(count: 2).title == "Failed")
        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        let italian = try #require(Bundle(path: path))
        #expect(String(localized: String.LocalizationValue(SidebarActivity.inProgress(count: 3).title), bundle: italian) == "In corso")
        #expect(String(localized: String.LocalizationValue(SidebarActivity.failed(count: 2).title), bundle: italian) == "Errore")
    }

    @Test("dictations wear the keyboard everywhere the category shows")
    func dictationGlyph() {
        #expect(DS.categorySymbol(for: .dictation) == "keyboard")
    }
}

@MainActor
@Suite("The sidebar on screen")
struct SidebarOnScreenTests {
    @Test("a row picked while its page can't open lets go of its highlight")
    func refusedPickLetsGo() async throws {
        let model = AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("sidebar-refused"))
        await model.libraryRefreshTask?.value
        let run = AppModel.Phase.transcribing(file: URL(fileURLWithPath: "/tmp/SidebarOnScreenTests.m4a"))
        model.phase = run
        let sidebar = HostedWindow(LibrarySidebar().environment(model), width: 240, height: 600)
        defer { sidebar.close() }
        _ = await waitUntil { sidebar.rowCount > 4 }
        let outline = try #require(sidebar.table)
        let library = try #require(sidebar.row(identifiedBy: "Sidebar.Row.Library"))
        #expect(outline.selectedRow == -1, "nothing is lit over the progress pane")

        outline.selectRowIndexes([library], byExtendingSelection: false)
        #expect(outline.selectedRow == library)

        let letGo = await waitUntil { outline.selectedRow == -1 }
        #expect(letGo, "the Library row stayed lit over the progress pane")
        #expect(model.phase == run, "the pick leaves the run alone")
    }
}
