import AppKit
import SwiftUI
import ParolaCore

/// Which of the library's two lists has the keyboard.
enum LibraryListFocus: Hashable {
    case browse
    case results
}

/// The rows of one library page, with their menu, drag and open gesture. Browsing and search results each own one.
struct LibraryRowList: View {
    enum Detail: Equatable {
        case excerpt
        case match(showsTimestamp: Bool)
    }

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let groups: [LibraryDateGroups.Group]
    @Binding var selection: Set<LibraryEntry.ID>
    let detail: Detail
    let animatesRows: Bool
    let rename: (LibraryEntry) -> Void
    let focus: FocusState<LibraryListFocus?>.Binding
    let focusKey: LibraryListFocus
    var rowAppeared: ((LibraryEntry.ID) -> Void)?

    /// Select All also takes the section rows, which are tagged with their groups' ids; only entries are kept.
    static func entries(in proposed: Set<LibraryEntry.ID>, groups: [LibraryDateGroups.Group]) -> Set<LibraryEntry.ID> {
        proposed.intersection(groups.lazy.flatMap(\.rows).map(\.id))
    }

    private var rowSelection: Binding<Set<LibraryEntry.ID>> {
        Binding(
            get: { selection },
            set: { selection = Self.entries(in: $0, groups: groups) }
        )
    }

    var body: some View {
        List(selection: rowSelection) {
            ForEach(groups) { group in
                Section {
                    ForEach(group.rows) { row in
                        LibraryListRow(
                            row: row,
                            detail: detail,
                            isSelected: selection.contains(row.id),
                            rename: rename
                        )
                        .equatable()
                        .onAppear { rowAppeared?(row.id) }
                    }
                } header: {
                    groupHeader(group)
                }
                .listSectionSeparator(.hidden)
            }
        }
        .listStyle(.inset)
        .tint(DS.Color.accentFill)
        .focused(focus, equals: focusKey)
        .animation(animatesRows && !reduceMotion ? DS.Motion.listRows : nil, value: groups.flatMap { $0.rows.map(\.id) })
        // Empty on purpose: each row keeps its own context menu, and the list takes only double-click and Return.
        .contextMenu(forSelectionType: LibraryEntry.ID.self) { _ in
        } primaryAction: { ids in
            openFromList(ids)
        }
    }

    /// The primary action doesn't carry the event's modifiers, so Option is read as it runs.
    private func openFromList(_ ids: Set<LibraryEntry.ID>) {
        guard let request = LibraryListContent.openRequest(for: ids, modifiers: NSEvent.modifierFlags) else { return }
        model.openEntryFromLibrary(request.id, inNewWindow: request.inNewWindow)
    }

    @ViewBuilder
    private func groupHeader(_ group: LibraryDateGroups.Group) -> some View {
        if let title = group.title {
            Text(verbatim: title)
                .font(DS.Font.body.weight(.semibold))
                .foregroundStyle(DS.Color.secondaryText)
                .textCase(nil)
                .listRowInsets(EdgeInsets(
                    top: DS.Spacing.regular,
                    leading: DS.Spacing.small,
                    bottom: DS.Spacing.tight,
                    trailing: DS.Spacing.small
                ))
                .accessibilityAddTraits(.isHeader)
        }
    }
}

/// One row with its menu. Equatable, so a click re-renders the rows whose selection moved, not all of them.
struct LibraryListRow: View, Equatable {
    @Environment(AppModel.self) private var model
    let row: LibraryRowDisplay
    let detail: LibraryRowList.Detail
    let isSelected: Bool
    let rename: (LibraryEntry) -> Void

    nonisolated static func == (lhs: LibraryListRow, rhs: LibraryListRow) -> Bool {
        lhs.row == rhs.row && lhs.detail == rhs.detail && lhs.isSelected == rhs.isSelected
    }

    var body: some View {
        let entry = row.entry
        return rowContent
            .contentShape(Rectangle())
            .draggable(entry.bundleURL)
            .contextMenu {
                Button("Open") {
                    model.openEntryFromLibrary(entry.id, inNewWindow: false)
                }
                Button("Open in New Window") {
                    model.openEntryWindow(entry.id)
                }
                .accessibilityIdentifier("library.row.\(entry.id).openInNewWindow")
                Button(entry.pinned ? "Unpin" : "Pin") {
                    model.togglePinned(for: entry.id)
                }
                .accessibilityIdentifier("library.row.\(entry.id).\(entry.pinned ? "unpin" : "pin")")
                Menu("Move to") {
                    ForEach(EntryCategory.allCases.filter { $0 != entry.category }, id: \.self) { target in
                        Button(LocalizedStringKey(libraryCategoryName(target))) {
                            model.moveEntry(entry.id, to: target)
                        }
                    }
                }
                .accessibilityIdentifier("library.row.\(entry.id).moveTo")
                if model.destinationsEnabled {
                    SendToMenu(model: model, entryID: entry.id)
                        .accessibilityIdentifier("library.row.\(entry.id).sendTo")
                }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([entry.bundleURL])
                }
                .accessibilityIdentifier("library.row.\(entry.id).revealInFinder")
                Button("Rename…") {
                    rename(entry)
                }
                .accessibilityIdentifier("library.row.\(entry.id).rename")
                Button("Delete", role: .destructive) {
                    model.deleteEntry(entry.id)
                }
                .accessibilityIdentifier("library.row.\(entry.id).delete")
            }
            .accessibilityIdentifier("library.row.\(entry.id)")
            // None: the row pads itself inside its hover wash, and List(.inset)'s own 16 pt lands its badge on the 24 pt gutter.
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private var rowContent: some View {
        switch detail {
        case .excerpt:
            EntryRow(display: row, detail: .excerpt(row.excerpt), isSelected: isSelected)
        case .match(let showsTimestamp):
            SearchResultRow(
                display: row,
                match: model.searchMatches[row.id],
                isSelected: isSelected,
                showsTimestamp: showsTimestamp
            )
        }
    }
}

/// Export and Delete for the rows a page has selected, in its header.
struct LibraryBulkActions: View {
    @Environment(AppModel.self) private var model
    let selection: Set<LibraryEntry.ID>
    @Binding var pendingBulkDelete: Bool

    /// One click selects a row, and that row's own menu covers it; the pills are for acting on several at once.
    static func isShown(forSelectionCount count: Int) -> Bool {
        count > 1
    }

    var body: some View {
        if Self.isShown(forSelectionCount: selection.count) {
            Menu {
                ForEach(ExportFormat.allCases) { format in
                    Button("\(format.displayName) (.\(format.fileExtension))") {
                        model.bulkExportEntries(ids: selection, format: format)
                    }
                    .axLeaf("Header.MenuItem.Export\(format.rawValue.capitalized)")
                }
            } label: {
                Text("Export (\(selection.count))")
            }
            .menuStyle(.button)
            .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
            .menuIndicator(.hidden)
            .fixedSize()
            .axLeaf("Header.Menu.BulkExport")
            Button {
                pendingBulkDelete = true
            } label: {
                Text(verbatim: RecentlyDeletedCopy.deleteSelection(selection.count))
                    .foregroundStyle(DS.Color.dangerText)
            }
            .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
            .axLeaf("Header.Button.BulkDelete")
        }
    }
}

/// The rename and bulk-delete alerts a page's rows and header raise.
struct LibraryListAlerts: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var selection: Set<LibraryEntry.ID>
    @Binding var pendingBulkDelete: Bool
    @Binding var renamingEntry: LibraryEntry?
    @Binding var renameDraft: String

    func body(content: Content) -> some View {
        content
            .alert("Delete \(selection.count) entries?", isPresented: $pendingBulkDelete) {
                Button("Cancel", role: .cancel) {}
                    .accessibilityIdentifier("alert.bulkDelete.cancel")
                Button("Delete", role: .destructive) { deleteSelection() }
                    .accessibilityIdentifier("alert.bulkDelete.confirm")
            } message: {
                Text("They'll move to Recently Deleted.")
            }
            .alert("Rename entry", isPresented: isRenaming) {
                TextField("Title", text: $renameDraft)
                Button("Cancel", role: .cancel) { renamingEntry = nil }
                    .accessibilityIdentifier("alert.rename.cancel")
                Button("Rename") {
                    if let id = renamingEntry?.id {
                        model.renameEntry(id, to: renameDraft)
                    }
                    renamingEntry = nil
                }
                .accessibilityIdentifier("alert.rename.confirm")
            }
    }

    private func deleteSelection() {
        let targets = selection
        selection.removeAll()
        for id in targets {
            model.deleteEntry(id)
        }
    }

    private var isRenaming: Binding<Bool> {
        Binding(
            get: { renamingEntry != nil },
            set: { if !$0 { renamingEntry = nil } }
        )
    }
}
