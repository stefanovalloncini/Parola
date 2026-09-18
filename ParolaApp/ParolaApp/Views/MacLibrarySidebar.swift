import SwiftUI
import ParolaCore

struct MacLibrarySidebar: View {
    @Environment(AppModel.self) private var model

    private var selectedRoute: SidebarRoute {
        SidebarRoute.selected(
            route: model.route,
            searching: model.searchResults != nil,
            filter: model.libraryFilter,
            browsingAll: model.libraryBrowsingAll
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

    private var searchBinding: Binding<String> {
        Binding(get: { model.searchQuery }, set: { model.search($0) })
    }

    var body: some View {
        VStack(spacing: 0) {
            SearchPill(text: searchBinding, placeholder: "Search history…", clearsOnEscape: true)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 10)

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
                        .padding(.top, 14)

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

                    if model.features.isEnabled(.batch) {
                        SectionLabel("Activity")
                            .padding(.top, 14)

                        SidebarRow(
                            title: "Queue",
                            systemImage: "list.bullet.indent",
                            isSelected: selectedRoute == .queue,
                            badge: activeQueueBadge
                        ) {
                            model.libraryFilter = nil
                            model.libraryBrowsingAll = false
                            model.route = .queue
                        }
                        .accessibilityIdentifier("library.queue")
                        .axLeaf("Sidebar.Button.Queue")

                        SidebarRow(
                            title: "Batch",
                            systemImage: "square.stack.3d.up",
                            isSelected: selectedRoute == .batch
                        ) {
                            model.libraryFilter = nil
                            model.libraryBrowsingAll = false
                            model.route = .batch
                        }
                        .accessibilityIdentifier("library.batch")
                        .axLeaf("Sidebar.Button.Batch")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }

            Spacer(minLength: 0)

            bottomPills
                .padding(.horizontal, 8)
                .padding(.vertical, 10)
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
            SectionLabel("Library")
            Spacer(minLength: 0)
            sortMenu
        }
        .padding(.trailing, 4)
    }

    private var sortMenu: some View {
        @Bindable var model = model
        return Menu {
            Picker("Sort", selection: $model.librarySortOrder) {
                ForEach(LibrarySortOrder.allCases) { order in
                    Text(order.label).tag(order)
                }
            }
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

    static func selected(
        route: AppModel.Route,
        searching: Bool,
        filter: EntryCategory?,
        browsingAll: Bool
    ) -> SidebarRoute {
        switch route {
        case .queue: return .queue
        case .batch: return .batch
        case .statistics: return .statistics
        case .recentlyDeleted: return .recentlyDeleted
        case .transcript:
            if searching { return .search }
            if let filter { return .category(filter) }
            return browsingAll ? .all : .home
        }
    }
}

private struct SectionLabel: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }
    var body: some View {
        SectionCaption(text)
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
    }
}
