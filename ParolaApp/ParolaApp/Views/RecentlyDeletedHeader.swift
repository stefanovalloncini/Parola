import SwiftUI
import ParolaCore

enum RecentlyDeletedCategoryFilter: String, CaseIterable, Identifiable {
    case all, transcriptions, meetings, dictations
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All Kinds"
        case .transcriptions: return "Transcriptions"
        case .meetings: return "Meetings"
        case .dictations: return "Dictations"
        }
    }

    var category: EntryCategory? {
        switch self {
        case .all: return nil
        case .transcriptions: return .transcription
        case .meetings: return .meeting
        case .dictations: return .dictation
        }
    }

    func matches(_ category: EntryCategory) -> Bool {
        guard let own = self.category else { return true }
        return own == category
    }
}

enum RecentlyDeletedSort: String, CaseIterable, Identifiable {
    case recentlyDeleted, deletedEarliest, titleAZ, titleZA
    var id: String { rawValue }

    var title: String {
        switch self {
        case .recentlyDeleted: return "Most Time Left"
        case .deletedEarliest: return "Expiring First"
        case .titleAZ: return "Title A→Z"
        case .titleZA: return "Title Z→A"
        }
    }

    var groupsByDate: Bool {
        switch self {
        case .recentlyDeleted, .deletedEarliest: return true
        case .titleAZ, .titleZA: return false
        }
    }
}

struct RecentlyDeletedHeader: View {
    @Environment(AppModel.self) private var model
    @Binding var searchText: String
    @Binding var categoryFilter: RecentlyDeletedCategoryFilter
    @Binding var sortOption: RecentlyDeletedSort
    @Binding var confirmingEmpty: Bool
    let onDone: () -> Void

    var body: some View {
        PageHeader(
            title: "Recently Deleted",
            subtitle: RecentlyDeletedCopy.subtitle(
                count: model.deletedEntries.count,
                retentionDays: AppModel.trashRetentionDays
            ),
            leading: { kindMenu },
            trailing: {
                SearchPill(
                    text: $searchText,
                    placeholder: "Search",
                    identifier: "RecentlyDeleted.Toolbar.TextField.Search",
                    clearButtonIdentifier: "RecentlyDeleted.Toolbar.Button.ClearSearch"
                )
                .frame(maxWidth: 220)
                sortMenu
                deleteAllButton
                Button("Done", action: onDone)
                    .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
                    .axLeaf("Toolbar.Button.Done")
            }
        )
    }

    private var kindMenu: some View {
        Menu {
            Button(LocalizedStringKey(RecentlyDeletedCategoryFilter.all.title)) { categoryFilter = .all }
                .axLeaf("Filter.MenuItem.Kind.all")
            Divider()
            ForEach(RecentlyDeletedCategoryFilter.allCases.filter { $0 != .all }) { option in
                Button(LocalizedStringKey(option.title)) { categoryFilter = option }
                    .axLeaf("Filter.MenuItem.Kind.\(option.rawValue)")
            }
        } label: {
            FilterPillLabel(systemImage: "square.grid.2x2", label: Text(LocalizedStringKey(categoryFilter.title)))
        }
        .menuStyle(.button)
        .buttonStyle(ChipButtonStyle(isSelected: categoryFilter != .all))
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Filter by kind")
        .axLeaf("Filter.Menu.Kind")
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort by", selection: $sortOption) {
                ForEach(RecentlyDeletedSort.allCases) { option in
                    Text(LocalizedStringKey(option.title)).tag(option)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .menuStyle(.button)
        .buttonStyle(DSIconChipButtonStyle(side: 26))
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort")
        .accessibilityLabel("Sort")
        .axLeaf("Toolbar.Menu.Sort")
    }

    private var deleteAllButton: some View {
        Button {
            confirmingEmpty = true
        } label: {
            Text("Delete All…")
                .foregroundStyle(DS.Color.dangerText)
        }
        .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
        .disabled(model.deletedEntries.isEmpty)
        .opacity(model.deletedEntries.isEmpty ? 0.5 : 1)
        .help("Delete every item in Recently Deleted")
        .axLeaf("Toolbar.Button.EmptyTrash")
    }
}
