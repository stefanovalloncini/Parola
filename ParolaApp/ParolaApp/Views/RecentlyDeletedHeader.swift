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
    @Binding var categoryFilter: RecentlyDeletedCategoryFilter
    @Binding var sortOption: RecentlyDeletedSort
    @Binding var confirmingEmpty: Bool
    let onRestoreSelection: () -> Void
    let onDeleteSelection: () -> Void

    var body: some View {
        PageHeader(
            title: "Recently Deleted",
            subtitle: RecentlyDeletedCopy.subtitle(
                count: model.deletedEntries.count,
                retentionDays: AppModel.trashRetentionDays
            ),
            leading: { kindMenu },
            trailing: {
                sortMenu
                if selection.isEmpty {
                    deleteAllButton
                } else {
                    restoreSelectionButton
                    deleteSelectionButton
                }
            }
        )
    }

    private var selection: Set<LibraryEntry.ID> { model.recentlyDeletedSelection }

    private var restoreSelectionButton: some View {
        Button(RecentlyDeletedCopy.restoreSelection(selection.count)) { onRestoreSelection() }
            .buttonStyle(DSPillButtonStyle(kind: .primary, size: .compact))
            .help("Put the selected items back in your library")
            .axLeaf("Selection.Button.Restore")
    }

    private var deleteSelectionButton: some View {
        Button {
            onDeleteSelection()
        } label: {
            Text(verbatim: RecentlyDeletedCopy.deleteSelection(selection.count))
                .foregroundStyle(DS.Color.dangerText)
        }
        .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
        .help("Delete the selected items for good")
        .axLeaf("Selection.Button.DeletePermanently")
    }

    private var kindMenu: some View {
        Menu {
            RecentlyDeletedKindItems(selection: $categoryFilter)
        } label: {
            FilterPillLabel(systemImage: "square.grid.2x2", label: Text(LocalizedStringKey(categoryFilter.title)))
        }
        .libraryHeaderChip(isActive: categoryFilter != .all)
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
        .help("Delete every item in Recently Deleted")
        .axLeaf("Toolbar.Button.EmptyTrash")
    }
}

/// The kind chip's label: a glyph and what the page is filtered to, both kept when the chip is drawn as a menu.
private struct FilterPillLabel: View {
    let systemImage: String
    let label: Text

    var body: some View {
        Label { label } icon: { Image(systemName: systemImage) }
            .labelStyle(.titleAndIcon)
    }
}

/// An inline picker, so the kind on show carries the tick.
struct RecentlyDeletedKindItems: View {
    @Binding var selection: RecentlyDeletedCategoryFilter

    var body: some View {
        Picker("Kind", selection: $selection) {
            Text(LocalizedStringKey(RecentlyDeletedCategoryFilter.all.title)).tag(RecentlyDeletedCategoryFilter.all)
            Divider()
            ForEach(RecentlyDeletedCategoryFilter.allCases.filter { $0 != .all }) { option in
                Text(LocalizedStringKey(option.title)).tag(option)
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }
}
