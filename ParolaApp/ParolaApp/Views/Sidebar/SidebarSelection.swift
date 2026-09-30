import Foundation
import ParolaCore

enum SidebarItem: Hashable {
    case library
    case category(EntryCategory)
    case person(UUID)
    case activity
    case recentlyDeleted
}

/// Which row the sidebar lights, derived from the page on screen rather than stored beside it.
enum SidebarSelection {
    struct Page: Equatable {
        var route: AppModel.Route
        var listShowing: Bool
        var searching: Bool
        var libraryFilter: EntryCategory?
        var personFilter: UUID?
    }

    static func current(_ page: Page, sidebarPeople: [UUID], showsActivity: Bool) -> SidebarItem? {
        switch destination(of: page) {
        case .person(let id)? where !sidebarPeople.contains(id): return nil
        case .activity? where !showsActivity: return nil
        case let item: return item
        }
    }

    /// The place on screen, row or no row; none over a transcript, a progress pane or results, as a native list ignores a click on its lit row.
    static func destination(of page: Page) -> SidebarItem? {
        switch page.route {
        case .recentlyDeleted: return .recentlyDeleted
        case .queue: return .activity
        case .batch, .statistics: return nil
        case .transcript:
            guard page.listShowing, !page.searching else { return nil }
            // A person picked in the header narrows the category; the person's own row means the whole library.
            if let category = page.libraryFilter { return .category(category) }
            if let person = page.personFilter { return .person(person) }
            return .library
        }
    }

    static func showsActivity(jobs: [BatchJob]) -> Bool {
        jobs.contains { [.pending, .transcribing, .failed].contains($0.status) }
    }
}
