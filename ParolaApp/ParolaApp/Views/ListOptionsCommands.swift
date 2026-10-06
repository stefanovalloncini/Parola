import SwiftUI
import ParolaCore

/// One pick-one list from a page's header, as the View menu repeats it.
struct ListMenuChoice {
    struct Option: Identifiable {
        let id: String
        let label: LocalizedStringKey
    }

    let options: [Option]
    let selected: String
    let choose: (String) -> Void
}

/// The sort and the filter of the list in front, so View ▸ Sort By and View ▸ Show offer what its header does.
@MainActor
struct PageListMenus {
    var sort: ListMenuChoice
    var show: ListMenuChoice?
    var groupsByDate: Binding<Bool>?
    var groupsByDateApplies = false

    static func library(_ model: AppModel) -> PageListMenus {
        PageListMenus(
            sort: ListMenuChoice(
                options: LibrarySortOrder.allCases.map { .init(id: $0.rawValue, label: LocalizedStringKey($0.label)) },
                selected: model.librarySortOrder.rawValue,
                choose: { raw in if let order = LibrarySortOrder(rawValue: raw) { model.librarySortOrder = order } }
            ),
            show: ListMenuChoice(
                options: LibraryDateRangeFilter.allCases.map { .init(id: $0.rawValue, label: $0.label) },
                selected: model.dateRangeFilter.rawValue,
                choose: { raw in if let range = LibraryDateRangeFilter(rawValue: raw) { model.dateRangeFilter = range } }
            ),
            groupsByDate: Binding(get: { model.libraryGroupsByDate }, set: { model.libraryGroupsByDate = $0 }),
            groupsByDateApplies: model.librarySortOrder.isChronological
        )
    }

    static func recentlyDeleted(
        sort: Binding<RecentlyDeletedSort>, kind: Binding<RecentlyDeletedCategoryFilter>
    ) -> PageListMenus {
        PageListMenus(
            sort: ListMenuChoice(
                options: RecentlyDeletedSort.allCases.map { .init(id: $0.rawValue, label: LocalizedStringKey($0.title)) },
                selected: sort.wrappedValue.rawValue,
                choose: { raw in if let order = RecentlyDeletedSort(rawValue: raw) { sort.wrappedValue = order } }
            ),
            show: ListMenuChoice(
                options: RecentlyDeletedCategoryFilter.allCases.map { .init(id: $0.rawValue, label: LocalizedStringKey($0.title)) },
                selected: kind.wrappedValue.rawValue,
                choose: { raw in if let filter = RecentlyDeletedCategoryFilter(rawValue: raw) { kind.wrappedValue = filter } }
            )
        )
    }

    static func queue(sort: Binding<QueueView.SortOption>) -> PageListMenus {
        PageListMenus(
            sort: ListMenuChoice(
                options: QueueView.SortOption.allCases.map { .init(id: $0.rawValue, label: LocalizedStringKey($0.rawValue)) },
                selected: sort.wrappedValue.rawValue,
                choose: { raw in if let order = QueueView.SortOption(rawValue: raw) { sort.wrappedValue = order } }
            )
        )
    }
}

extension FocusedValues {
    @Entry var pageListMenus: PageListMenus?
}

/// Publishes the library's sort and date filter while its list is in front, not while results cover it.
struct LibraryListMenusPublisher: View {
    @Environment(AppModel.self) private var model
    let listShows: Bool

    var body: some View {
        Color.clear
            .focusedSceneValue(\.pageListMenus, listShows && !model.hasSearchResults ? .library(model) : nil)
    }
}

struct ListOptionsCommands: View {
    @FocusedValue(\.pageListMenus) private var menus

    var body: some View {
        Menu("Sort By") {
            if let menus {
                choices(menus.sort)
                if let groupsByDate = menus.groupsByDate {
                    Divider()
                    Toggle("Group by Date", isOn: groupsByDate)
                        .disabled(!menus.groupsByDateApplies)
                }
            }
        }
        .disabled(menus == nil)
        .axLeaf("Menu.View.SortBy")
        Menu("Show") {
            if let show = menus?.show {
                choices(show)
            }
        }
        .disabled(menus?.show == nil)
        .axLeaf("Menu.View.Show")
    }

    private func choices(_ choice: ListMenuChoice) -> some View {
        ForEach(choice.options) { option in
            Toggle(isOn: Binding(get: { choice.selected == option.id }, set: { if $0 { choice.choose(option.id) } })) {
                Text(option.label)
            }
        }
    }
}
