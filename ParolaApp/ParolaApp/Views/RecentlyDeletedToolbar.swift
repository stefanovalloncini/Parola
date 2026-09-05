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
        case .older: return "Past Deadline"
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

struct RecentlyDeletedToolbar: View {
    @Environment(AppModel.self) private var model
    @Binding var searchText: String
    @Binding var sortOption: RecentlyDeletedSort
    @Binding var confirmingEmpty: Bool
    let expiringSoon: Int
    let onDone: () -> Void

    var body: some View {
        HStack(spacing: DS.Spacing.regular) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Recently Deleted")
                    .font(DS.Font.title2)
                if !model.deletedEntries.isEmpty {
                    subtitle
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.secondaryText)
                }
            }
            Spacer(minLength: DS.Spacing.regular)
            searchField
            sortMenu
            actionMenu
            Button("Done", action: onDone)
                .keyboardShortcut(.defaultAction)
                .axLeaf("Toolbar.Button.Done")
        }
        .padding(.horizontal, DS.Spacing.regular)
        .padding(.vertical, DS.Spacing.small)
    }

    private var subtitle: Text {
        var line = AttributedString(RecentlyDeletedCopy.subtitleCount(model.deletedEntries.count))
        if expiringSoon > 0 {
            line.append(AttributedString(" · "))
            var clause = AttributedString(RecentlyDeletedCopy.subtitleExpiring(expiringSoon))
            clause.font = DS.Font.captionEmphasized
            clause.foregroundColor = DS.Color.dangerText
            line.append(clause)
        }
        return Text(line)
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
                    Text(LocalizedStringKey(option.title)).tag(option)
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
            Button("Delete All Now", role: .destructive) {
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
}

struct RecentlyDeletedFilterBar: View {
    @Binding var dateFilter: RecentlyDeletedDateFilter
    @Binding var categoryFilter: RecentlyDeletedCategoryFilter

    var body: some View {
        // Both groups on one line at the ideal sheet width; stacked at the minimum, where the
        // last kind pill would otherwise sit outside the sheet.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                whenGroup
                kindGroup
                    .padding(.leading, DS.Spacing.tight)
            }
            VStack(alignment: .leading, spacing: DS.Spacing.small) {
                HStack(spacing: 6) { whenGroup }
                HStack(spacing: 6) { kindGroup }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DS.Spacing.regular)
        .padding(.vertical, DS.Spacing.small)
    }

    @ViewBuilder
    private var whenGroup: some View {
        caption("When")
        ForEach(RecentlyDeletedDateFilter.allCases) { option in
            Chip(
                title: LocalizedStringKey(option.title),
                isSelected: dateFilter == option,
                size: .compact,
                weight: .semibold
            ) {
                dateFilter = option
            }
        }
    }

    @ViewBuilder
    private var kindGroup: some View {
        caption("Kind")
        ForEach(RecentlyDeletedCategoryFilter.allCases) { option in
            Chip(
                title: LocalizedStringKey(option.title),
                tint: dot(for: option),
                isSelected: categoryFilter == option,
                size: .compact,
                weight: .semibold
            ) {
                categoryFilter = option
            }
        }
    }

    private func caption(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(DS.Font.caption2Emphasized)
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(DS.Color.secondaryText)
    }

    private func dot(for option: RecentlyDeletedCategoryFilter) -> Color? {
        guard let category = option.category, categoryFilter != option else { return nil }
        return DS.categoryTint(for: category)
    }
}

struct RecentlyDeletedPillChrome: View {
    var body: some View {
        Capsule(style: .continuous)
            .fill(DS.Color.surfaceElevated.opacity(0.85))
            .overlay(
                Capsule(style: .continuous)
                    .stroke(DS.Color.separator.opacity(0.4), lineWidth: 0.5)
            )
    }
}
