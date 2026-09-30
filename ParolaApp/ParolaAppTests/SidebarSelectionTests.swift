import Foundation
import Testing
@testable import Parola
import ParolaCore

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

    @Test("Activity shows while a job waits, runs or failed")
    func activity() {
        let file = URL(fileURLWithPath: "/tmp/a.m4a")
        #expect(!SidebarSelection.showsActivity(jobs: []))
        #expect(SidebarSelection.showsActivity(jobs: [BatchJob(url: file, status: .pending)]))
        #expect(SidebarSelection.showsActivity(jobs: [BatchJob(url: file, status: .transcribing)]))
        #expect(SidebarSelection.showsActivity(jobs: [BatchJob(url: file, status: .failed)]))
        #expect(!SidebarSelection.showsActivity(jobs: [BatchJob(url: file, status: .done), BatchJob(url: file, status: .cancelled)]))
    }

    @Test("dictations wear the keyboard everywhere the category shows")
    func dictationGlyph() {
        #expect(DS.categorySymbol(for: .dictation) == "keyboard")
    }
}
