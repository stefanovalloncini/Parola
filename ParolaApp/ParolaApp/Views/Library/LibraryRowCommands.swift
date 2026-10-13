import SwiftUI
import ParolaCore

/// The rows a focused library list has selected, as the File menu's row commands act on them.
struct LibraryRowsTarget: Equatable {
    let ids: [LibraryEntry.ID]
    let pins: Bool
    let renameTargetID: LibraryEntry.ID?
    let rename: (LibraryEntry) -> Void
    let delete: (Set<LibraryEntry.ID>) -> Void

    init(entries: [LibraryEntry], rename: @escaping (LibraryEntry) -> Void, delete: @escaping (Set<LibraryEntry.ID>) -> Void) {
        ids = entries.map(\.id)
        pins = Self.pins(entries)
        renameTargetID = entries.count == 1 ? entries.first?.id : nil
        self.rename = rename
        self.delete = delete
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.ids == rhs.ids && lhs.pins == rhs.pins && lhs.renameTargetID == rhs.renameTargetID
    }

    /// Pin unless every row is pinned already, as Mail's Flag does for a mixed selection.
    static func pins(_ entries: [LibraryEntry]) -> Bool {
        entries.contains { !$0.pinned }
    }

    /// The shelf's entries come first, as they sit above the list.
    static func selectedEntries(
        _ selection: Set<LibraryEntry.ID>, in items: [LibraryListItem], shelf: [LibraryRowDisplay] = []
    ) -> [LibraryEntry] {
        let shelved = shelf.lazy.filter { selection.contains($0.id) }.map(\.entry)
        let listed = items.lazy.compactMap { item -> LibraryEntry? in
            guard case .entry(let row) = item, selection.contains(row.id) else { return nil }
            return row.entry
        }
        return Array(shelved) + Array(listed)
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
        let hasRows = !(rows?.ids.isEmpty ?? true)
        Divider()
        Button(rows?.pins == false ? "Unpin" : "Pin") {
            guard let rows else { return }
            model.setPinned(rows.pins, for: rows.ids)
        }
        .disabled(!hasRows)
        .axLeaf("Menu.File.Pin")
        Button("Rename…") {
            guard let rows, let id = rows.renameTargetID, let entry = model.libraryEntry(id: id) else { return }
            rows.rename(entry)
        }
        .disabled(rows?.renameTargetID == nil)
        .axLeaf("Menu.File.Rename")
        Button("Move to Recently Deleted") { if let rows { rows.delete(Set(rows.ids)) } }
            .keyboardShortcut(.delete, modifiers: [.command])
            .disabled(!hasRows)
            .axLeaf("Menu.File.MoveToRecentlyDeleted")
    }
}
