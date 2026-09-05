import SwiftUI
import ParolaCore

struct MacLibrarySidebar: View {
    @Environment(AppModel.self) private var model
    @State private var searchText = ""

    private var selectedRoute: SidebarRoute {
        switch model.route {
        case .queue: return .queue
        case .batch: return .batch
        case .transcript:
            if let filter = model.libraryFilter { return .category(filter) }
            if model.libraryBrowsingAll { return .all }
            return .home
        }
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
            SearchPill(text: $searchText, placeholder: "Search history…")
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
                        model.libraryFilter = nil
                        model.libraryBrowsingAll = true
                        model.route = .transcript
                    }
                    .accessibilityIdentifier("library.filter.all")
                    .axLeaf("Sidebar.Button.FilterAll")

                    ForEach(categories, id: \.id) { item in
                        SidebarRow(
                            title: item.title,
                            systemImage: item.systemImage,
                            isSelected: selectedRoute == .category(item.category)
                        ) {
                            model.libraryFilter = item.category
                            model.libraryBrowsingAll = false
                            model.route = .transcript
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
        .onChange(of: searchText) { _, newValue in model.search(newValue) }
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
            Button {
                model.showingTrash = true
            } label: {
                PillRowContent(title: "Recently Deleted", systemImage: "trash", badge: deletedBadge)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("library.recentlyDeleted")
            .axLeaf("Sidebar.Button.RecentlyDeleted")

            SettingsLink {
                PillRowContent(title: "Settings", systemImage: "gearshape.fill")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("library.settings")
            .axLeaf("Sidebar.Button.Settings")
        }
    }
}

private enum SidebarRoute: Hashable {
    case home
    case all
    case queue
    case batch
    case category(EntryCategory)
}

private struct SectionLabel: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }
    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
    }
}

private struct PillRowContent: View {
    let title: LocalizedStringKey
    let systemImage: String
    var badge: Int? = nil

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(DS.Font.bodyMedium)
                .frame(width: 18, alignment: .center)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.subheadline)
            Spacer(minLength: 0)
            if let badge {
                Text("\(badge)")
                    .font(DS.Font.captionMedium)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.10)))
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                .fill(isHovering ? DS.Palette.surfaceHover : Color.clear)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}
