import SwiftUI
import ParolaCore

enum RecentlyDeletedDateFilter: String, CaseIterable, Identifiable {
    case all, today, week, month, older
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .today: return "Today"
        case .week: return "This Week"
        case .month: return "This Month"
        case .older: return "Older"
        }
    }
}

enum RecentlyDeletedCategoryFilter: String, CaseIterable, Identifiable {
    case all, transcriptions, meetings, dictations
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .transcriptions: return "Transcriptions"
        case .meetings: return "Meetings"
        case .dictations: return "Dictations"
        }
    }

    func matches(_ category: EntryCategory) -> Bool {
        switch self {
        case .all: return true
        case .transcriptions: return category == .transcription
        case .meetings: return category == .meeting
        case .dictations: return category == .dictation
        }
    }
}

enum RecentlyDeletedSort: String, CaseIterable, Identifiable {
    case recentlyDeleted, deletedEarliest, titleAZ, titleZA
    var id: String { rawValue }

    var title: String {
        switch self {
        case .recentlyDeleted: return "Recently deleted"
        case .deletedEarliest: return "Deleted earliest"
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

struct RecentlyDeletedToolbar: View {
    @Environment(AppModel.self) private var model
    @Binding var searchText: String
    @Binding var sortOption: RecentlyDeletedSort
    @Binding var confirmingEmpty: Bool
    let onDone: () -> Void

    var body: some View {
        HStack(spacing: DS.Spacing.regular) {
            Text("Recently Deleted")
                .font(.system(.title2, design: .default, weight: .semibold))
            Spacer(minLength: DS.Spacing.regular)
            searchField
            sortMenu
            actionMenu
            emptyTrashButton
            Button("Done", action: onDone)
                .keyboardShortcut(.defaultAction)
                .axLeaf("Toolbar.Button.Done")
        }
        .padding(.horizontal, DS.Spacing.regular)
        .padding(.vertical, DS.Spacing.small)
    }

    var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(DS.Font.callout)
                .foregroundStyle(.secondary)
            TextField("Search", text: $searchText)
                .textFieldStyle(.plain)
                .frame(minWidth: 140, maxWidth: 200)
                .axLeaf("Toolbar.TextField.Search")
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(DS.Font.callout)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .axLeaf("Toolbar.Button.ClearSearch")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(RecentlyDeletedPillChrome())
    }

    var sortMenu: some View {
        Menu {
            Picker("Sort by", selection: $sortOption) {
                ForEach(RecentlyDeletedSort.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "chevron.up.chevron.down")
                .font(DS.Font.subheadlineEmphasized)
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 26)
                .background(RecentlyDeletedPillChrome())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort")
        .accessibilityLabel("Sort")
        .axLeaf("Toolbar.Menu.Sort")
    }

    var actionMenu: some View {
        Menu {
            Button("Restore All") {
                for entry in model.deletedEntries { model.restoreEntry(entry.id) }
            }
            .disabled(model.deletedEntries.isEmpty)
            .axLeaf("Toolbar.MenuItem.RestoreAll")
            Divider()
            Button("Empty Recently Deleted", role: .destructive) {
                confirmingEmpty = true
            }
            .disabled(model.deletedEntries.isEmpty)
            .axLeaf("Toolbar.MenuItem.EmptyTrash")
        } label: {
            Image(systemName: "ellipsis")
                .font(DS.Font.heading)
                .frame(width: 28, height: 26)
                .background(RecentlyDeletedPillChrome())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More actions")
        .accessibilityLabel("More actions")
        .axLeaf("Toolbar.Menu.Actions")
    }

    var emptyTrashButton: some View {
        Button { confirmingEmpty = true } label: {
            Image(systemName: "trash")
                .font(DS.Font.calloutEmphasized)
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 26)
                .background(RecentlyDeletedPillChrome())
        }
        .buttonStyle(.plain)
        .disabled(model.deletedEntries.isEmpty)
        .help("Empty Recently Deleted")
        .accessibilityLabel("Empty Recently Deleted")
        .axLeaf("Toolbar.Button.EmptyTrash")
    }
}

struct RecentlyDeletedFilterBar: View {
    @Binding var dateFilter: RecentlyDeletedDateFilter
    @Binding var categoryFilter: RecentlyDeletedCategoryFilter

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            chipRow(
                label: "When",
                options: RecentlyDeletedDateFilter.allCases,
                selection: $dateFilter,
                title: \.title
            )
            chipRow(
                label: "Kind",
                options: RecentlyDeletedCategoryFilter.allCases,
                selection: $categoryFilter,
                title: \.title
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DS.Spacing.regular)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func chipRow<Option: Identifiable & Hashable>(
        label: String,
        options: [Option],
        selection: Binding<Option>,
        title: KeyPath<Option, String>
    ) -> some View {
        HStack(spacing: 6) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .leading)
            ForEach(options) { option in
                Chip(
                    title: LocalizedStringKey(option[keyPath: title]),
                    isSelected: selection.wrappedValue == option,
                    size: .compact,
                    weight: .semibold
                ) {
                    selection.wrappedValue = option
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct RecentlyDeletedPillChrome: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 13, style: .continuous)
            .fill(DS.Color.surfaceElevated.opacity(0.85))
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(DS.Color.separator.opacity(0.4), lineWidth: 0.5)
            )
    }
}
