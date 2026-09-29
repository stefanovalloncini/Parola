import SwiftUI
import ParolaCore

struct MacLibrarySidebar: View {
    @Environment(AppModel.self) private var model

    private var selectedRoute: SidebarRoute {
        SidebarRoute.selected(
            route: model.route,
            searching: model.hasSearchResults,
            filter: model.libraryFilter,
            browsingAll: model.libraryBrowsingAll,
            person: model.personFilter
        )
    }

    private var categories: [(title: LocalizedStringKey, id: String, systemImage: String, category: EntryCategory)] {
        var rows: [(LocalizedStringKey, String, EntryCategory)] = [
            ("Transcriptions", "transcriptions", .transcription)
        ]
        if model.features.isEnabled(.meetings) {
            rows.append(("Meetings", "meetings", .meeting))
        }
        if model.features.isEnabled(.dictation) {
            rows.append(("Dictations", "dictations", .dictation))
        }
        return rows.map {
            (title: $0.0, id: $0.1, systemImage: DS.categorySymbol(for: $0.2), category: $0.2)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    SidebarRow(
                        title: "Home",
                        systemImage: "house.fill",
                        isSelected: selectedRoute == .home
                    ) {
                        model.goHome()
                    }
                    .accessibilityIdentifier("library.home")
                    .axLeaf("Sidebar.Button.Home")

                    librarySectionHeader
                        .padding(.top, DS.Spacing.regular)

                    SidebarRow(
                        title: "All",
                        systemImage: "tray.full",
                        isSelected: selectedRoute == .all
                    ) {
                        model.browseAll()
                    }
                    .accessibilityIdentifier("library.filter.all")
                    .axLeaf("Sidebar.Button.FilterAll")

                    ForEach(categories, id: \.id) { item in
                        SidebarRow(
                            title: item.title,
                            systemImage: item.systemImage,
                            isSelected: selectedRoute == .category(item.category)
                        ) {
                            model.browseCategory(item.category)
                        }
                        .accessibilityIdentifier("library.filter.\(item.id)")
                        .axLeaf("Sidebar.Button.Filter\(item.id.capitalized)")
                    }

                    PeopleSidebarSection()

                    if model.features.isEnabled(.batch) {
                        SidebarSectionLabel("Activity")
                            .padding(.top, DS.Spacing.regular)

                        SidebarRow(
                            title: "Queue",
                            systemImage: "list.bullet.indent",
                            isSelected: selectedRoute == .queue,
                            badge: activeQueueBadge
                        ) {
                            model.openQueue()
                        }
                        .accessibilityIdentifier("library.queue")
                        .axLeaf("Sidebar.Button.Queue")

                        SidebarRow(
                            title: "Batch",
                            systemImage: "square.stack.3d.up",
                            isSelected: selectedRoute == .batch
                        ) {
                            model.openBatch()
                        }
                        .accessibilityIdentifier("library.batch")
                        .axLeaf("Sidebar.Button.Batch")
                    }

                    if let store = model.watchedFoldersIfWatching {
                        UnavailableWatchedFolders(store: store)
                    }
                }
                .padding(.horizontal, DS.Spacing.small)
                .padding(.top, DS.Spacing.regular)
                .padding(.bottom, DS.Spacing.small)
            }

            Spacer(minLength: 0)

            bottomPills
                .padding(.horizontal, DS.Spacing.small)
                .padding(.vertical, DS.Spacing.small)
        }
        .navigationSplitViewColumnWidth(
            min: MainWindowLayout.sidebarMinWidth,
            ideal: MainWindowLayout.sidebarIdealWidth,
            max: MainWindowLayout.sidebarMaxWidth
        )
    }

    private var activeQueueBadge: Int? {
        let n = model.activeBatchJobCount
        return n > 0 ? n : nil
    }

    private var deletedBadge: Int? {
        let n = model.deletedEntries.count
        return n > 0 ? n : nil
    }

    private var librarySectionHeader: some View {
        HStack(spacing: 0) {
            SidebarSectionLabel("Library")
            Spacer(minLength: 0)
            sortMenu
        }
        .padding(.trailing, DS.Spacing.tight)
    }

    private var sortMenu: some View {
        @Bindable var model = model
        return Menu {
            Picker("Sort", selection: $model.librarySortOrder) {
                ForEach(LibrarySortOrder.allCases) { order in
                    Text(LocalizedStringKey(order.label)).tag(order)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .menuStyle(.button)
        .buttonStyle(DSIconChipButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort")
        .axLeaf("Sidebar.Menu.Sort")
    }

    private var bottomPills: some View {
        VStack(spacing: 6) {
            SidebarRow(
                title: "Statistics",
                systemImage: "chart.bar",
                isSelected: selectedRoute == .statistics,
                height: 30,
                bordered: true
            ) {
                model.openStatistics()
            }
            .accessibilityIdentifier("library.statistics")
            .axLeaf("Sidebar.Button.Statistics")

            SidebarRow(
                title: "Recently Deleted",
                systemImage: "trash",
                isSelected: selectedRoute == .recentlyDeleted,
                badge: deletedBadge,
                height: 30,
                bordered: true
            ) {
                model.openRecentlyDeleted()
            }
            .accessibilityIdentifier("library.recentlyDeleted")
            .axLeaf("Sidebar.Button.RecentlyDeleted")

            SettingsLink {
                SidebarRowLabel(
                    title: "Settings",
                    systemImage: "gearshape.fill",
                    height: 30,
                    bordered: true
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("library.settings")
            .axLeaf("Sidebar.Button.Settings")
        }
    }
}

enum SidebarRoute: Hashable {
    /// No row owns the search results, so none is highlighted while they show.
    case search
    case home
    case all
    case queue
    case batch
    case statistics
    case recentlyDeleted
    case category(EntryCategory)
    case person(UUID)

    static func selected(
        route: AppModel.Route,
        searching: Bool,
        filter: EntryCategory?,
        browsingAll: Bool,
        person: UUID? = nil
    ) -> SidebarRoute {
        switch route {
        case .queue: return .queue
        case .batch: return .batch
        case .statistics: return .statistics
        case .recentlyDeleted: return .recentlyDeleted
        case .transcript:
            if searching { return .search }
            // A category narrowed by the filter-bar chip keeps the category row lit, not the person.
            if let person, filter == nil { return .person(person) }
            if let filter { return .category(filter) }
            return browsingAll ? .all : .home
        }
    }
}

struct SidebarSectionLabel: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }
    var body: some View {
        SectionCaption(text)
            .padding(.horizontal, DS.Spacing.small)
            .padding(.bottom, DS.Spacing.tight)
    }
}
