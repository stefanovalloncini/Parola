import SwiftUI
import ParolaCore

/// The rows a focused library list has selected, as the File menu's row commands act on them.
struct LibraryRowsTarget {
    let entries: [LibraryEntry]
    let rename: (LibraryEntry) -> Void
    let delete: () -> Void

    /// Pin unless every selected row is pinned already, as Mail's Flag does for a mixed selection.
    var pins: Bool { entries.contains { !$0.pinned } }

    var renameTarget: LibraryEntry? { entries.count == 1 ? entries.first : nil }

    static func selectedEntries(_ selection: Set<LibraryEntry.ID>, in items: [LibraryListItem]) -> [LibraryEntry] {
        items.compactMap { item in
            guard case .entry(let row) = item, selection.contains(row.id) else { return nil }
            return row.entry
        }
    }
}

/// One row goes at once; several ask first, as the header's Delete does.
enum LibraryDeleteRequest: Equatable {
    case none
    case now
    case confirm

    static func forSelection(count: Int) -> LibraryDeleteRequest {
        switch count {
        case 0: .none
        case 1: .now
        default: .confirm
        }
    }
}

extension FocusedValues {
    @Entry var libraryRows: LibraryRowsTarget?
}

struct LibraryRowCommands: View {
    let model: AppModel
    @FocusedValue(\.libraryRows) private var rows

    var body: some View {
        let entries = rows?.entries ?? []
        Divider()
        Button(rows?.pins == false ? "Unpin" : "Pin") {
            guard let rows else { return }
            model.setPinned(rows.pins, for: rows.entries.map(\.id))
        }
        .disabled(entries.isEmpty)
        .axLeaf("Menu.File.Pin")
        Button("Rename…") {
            guard let rows, let entry = rows.renameTarget else { return }
            rows.rename(entry)
        }
        .disabled(rows?.renameTarget == nil)
        .axLeaf("Menu.File.Rename")
        Button("Move to Recently Deleted") { rows?.delete() }
            .keyboardShortcut(.delete, modifiers: [.command])
            .disabled(entries.isEmpty)
            .axLeaf("Menu.File.MoveToRecentlyDeleted")
    }
}
