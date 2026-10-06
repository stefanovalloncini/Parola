import AppKit
import SwiftUI
import ParolaCore

/// Which of the library's two lists has the keyboard.
enum LibraryListFocus: Hashable {
    case browse
    case results
}

/// One row of a library list: a date group's title, or an entry under it.
enum LibraryListItem: Identifiable, Equatable {
    case header(id: String, title: String)
    case entry(LibraryRowDisplay)

    /// The page's own top, the row a list puts before every item.
    static let pageTopID = "page/top"

    var id: String {
        switch self {
        // A file name can't hold a slash, so no entry id takes this form.
        case .header(let id, _): return "header/\(id)"
        case .entry(let row): return row.id
        }
    }

    /// Titles and entries in one run, so a title scrolls away with the rows under it; an untitled group adds none.
    static func items(for groups: [LibraryDateGroups.Group]) -> [LibraryListItem] {
        var items: [LibraryListItem] = []
        items.reserveCapacity(groups.reduce(0) { $0 + $1.rows.count + 1 })
        for group in groups {
            if let title = group.title {
                items.append(.header(id: group.id, title: title))
            }
            items.append(contentsOf: group.rows.lazy.map(LibraryListItem.entry))
        }
        return items
    }

    /// Select All also takes the title rows, which are tagged with ids of their own; only entries are kept.
    static func entries(in proposed: Set<LibraryEntry.ID>, items: [LibraryListItem]) -> Set<LibraryEntry.ID> {
        proposed.intersection(items.lazy.compactMap { item -> LibraryEntry.ID? in
            if case .entry(let row) = item { return row.id }
            return nil
        })
    }
}

/// The rows of one library page, with their menu, drag and open gesture. Browsing and search results each own one.
struct LibraryRowList<Top: View>: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let items: [LibraryListItem]
    /// Taken once with the items, since a click re-runs the body and the rows animate on their ids alone.
    private let itemIDs: [String]
    @Binding var selection: Set<LibraryEntry.ID>
    let detail: LibraryListRow.Detail
    let animatesRows: Bool
    let rename: (LibraryEntry) -> Void
    @Binding var pendingBulkDelete: Bool
    let focus: FocusState<LibraryListFocus?>.Binding
    let focusKey: LibraryListFocus
    var rowAppeared: ((LibraryEntry.ID) -> Void)?
    /// The page's own top as the list's first row, so it scrolls away with the rows under it.
    var top: Top?

    init(
        items: [LibraryListItem],
        selection: Binding<Set<LibraryEntry.ID>>,
        detail: LibraryListRow.Detail,
        animatesRows: Bool,
        rename: @escaping (LibraryEntry) -> Void,
        pendingBulkDelete: Binding<Bool>,
        focus: FocusState<LibraryListFocus?>.Binding,
        focusKey: LibraryListFocus,
        rowAppeared: ((LibraryEntry.ID) -> Void)? = nil,
        top: Top? = nil
    ) {
        self.items = items
        itemIDs = items.map(\.id)
        _selection = selection
        self.detail = detail
        self.animatesRows = animatesRows
        self.rename = rename
        _pendingBulkDelete = pendingBulkDelete
        self.focus = focus
        self.focusKey = focusKey
        self.rowAppeared = rowAppeared
        self.top = top
    }

    /// List(.inset) indents its rows by 16 pt of its own; this lands a title on the 24 pt gutter.
    private static var titleInsets: EdgeInsets {
        EdgeInsets(top: 0, leading: DS.Spacing.small, bottom: 0, trailing: DS.Spacing.small)
    }

    private var rowSelection: Binding<Set<LibraryEntry.ID>> {
        Binding(
            get: { selection },
            set: { selection = LibraryListItem.entries(in: $0, items: items) }
        )
    }

    var body: some View {
        List(selection: rowSelection) {
            if let top {
                top
                    .listRowInsets(Self.titleInsets)
                    .listRowSeparator(.hidden)
                    .selectionDisabled()
                    .id(LibraryListItem.pageTopID)
            }
            ForEach(items) { item in
                switch item {
                case .header(_, let title):
                    LibraryGroupHeader(title: title)
                        .listRowInsets(Self.titleInsets)
                        .listRowSeparator(.hidden)
                        .selectionDisabled()
                case .entry(let row):
                    LibraryListRow(
                        row: row,
                        detail: detail,
                        isSelected: selection.contains(row.id),
                        rename: rename
                    )
                    .equatable()
                    .onAppear { rowAppeared?(row.id) }
                    // On the element, not in the row's body: behind `.equatable()` the list doesn't read them.
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.inset)
        .tint(DS.Color.accentFill)
        .focused(focus, equals: focusKey)
        .focusedValue(\.libraryRows, LibraryRowsTarget(
            entries: LibraryRowsTarget.selectedEntries(selection, in: items), rename: rename, delete: deleteSelection
        ))
        .onDeleteCommand(perform: deleteSelection)
        .animation(animatesRows && !reduceMotion ? DS.Motion.listRows : nil, value: itemIDs)
        .contextMenu(forSelectionType: LibraryEntry.ID.self) { ids in
            LibraryRowMenu(
                model: model,
                entries: LibraryRowsTarget.selectedEntries(ids, in: items),
                rename: rename,
                delete: delete
            )
        } primaryAction: { ids in
            openFromList(ids)
        }
    }

    /// The primary action doesn't carry the event's modifiers, so Option is read as it runs; a title row opens nothing.
    private func openFromList(_ ids: Set<LibraryEntry.ID>) {
        let entries = LibraryListItem.entries(in: ids, items: items)
        guard let request = LibraryListContent.openRequest(for: entries, modifiers: NSEvent.modifierFlags) else { return }
        model.openEntryFromLibrary(request.id, inNewWindow: request.inNewWindow)
    }

    private func deleteSelection() {
        delete(LibraryListItem.entries(in: selection, items: items))
    }

    /// Several rows ask first, and the alert deletes the selection, so they become it.
    private func delete(_ ids: Set<LibraryEntry.ID>) {
        switch LibraryDeleteRequest.forSelection(count: ids.count) {
        case .none:
            break
        case .now:
            selection.subtract(ids)
            model.deleteEntries(Array(ids))
        case .confirm:
            selection = ids
            pendingBulkDelete = true
        }
    }
}

/// A date group's title as a row of its own, on the gutter the rows' badges start on.
struct LibraryGroupHeader: View {
    let title: String

    var body: some View {
        Text(verbatim: title)
            .font(DS.Font.body.weight(.semibold))
            .foregroundStyle(DS.Color.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, DS.Spacing.regular)
            .padding(.bottom, DS.Spacing.tight)
            .accessibilityAddTraits(.isHeader)
    }
}

/// One row with its menu. Equatable, so a click re-renders the rows whose selection moved, not all of them.
struct LibraryListRow: View, Equatable {
    enum Detail: Equatable {
        case excerpt
        case match(showsTimestamp: Bool)
    }

    // Optional: AppKit can build a List cell after SwiftUI tore the List down, and a required read traps "No Observable object of type AppModel found".
    @Environment(AppModel.self) private var model: AppModel?
    let row: LibraryRowDisplay
    let detail: Detail
    let isSelected: Bool
    let rename: (LibraryEntry) -> Void

    nonisolated static func == (lhs: LibraryListRow, rhs: LibraryListRow) -> Bool {
        lhs.row == rhs.row && lhs.detail == rhs.detail && lhs.isSelected == rhs.isSelected
    }

    var body: some View {
        let entry = row.entry
        return rowContent
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: LibraryRowFormat.spokenLabel(for: row, detail: spokenDetail)))
            // The list's context menu reaches VoiceOver too; these put its everyday items in the Actions rotor, in its order.
            .accessibilityActions {
                if let model { actions(for: entry, model: model) }
            }
            .contentShape(Rectangle())
            .draggable(entry.bundleURL)
            .accessibilityIdentifier("library.row.\(entry.id)")
    }

    /// What the row's second line says, and for a search hit, where and how often it matched.
    private var spokenDetail: [String] {
        switch detail {
        case .excerpt:
            return [row.excerpt ?? ""]
        case .match:
            let match = model?.searchMatches[row.id]
            var parts = [match?.snippet ?? ""]
            if let timecode = SearchResultRow.timestamp(for: match) { parts.append(String(localized: "First match at \(timecode)")) }
            if let count = match?.matchCount, count > 0 { parts.append(LibraryListContent.matchesLabel(count)) }
            return parts
        }
    }

    @ViewBuilder
    private func actions(for entry: LibraryEntry, model: AppModel) -> some View {
        Button("Open") { model.openEntryFromLibrary(entry.id, inNewWindow: false) }
        Button("Open in New Window") { model.openEntryWindow(entry.id) }
        Button("Export…") { model.exportEntryFromLibrary(entry.id) }
        Button(entry.pinned ? "Unpin" : "Pin") { model.togglePinned(for: entry.id) }
        Button("Rename…") { rename(entry) }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.bundleURL]) }
        Button("Delete") { model.deleteEntry(entry.id) }
    }

    @ViewBuilder
    private var rowContent: some View {
        switch detail {
        case .excerpt:
            EntryRow(display: row, detail: .excerpt(row.excerpt), isSelected: isSelected)
        case .match(let showsTimestamp):
            SearchResultRow(
                display: row,
                match: model?.searchMatches[row.id],
                isSelected: isSelected,
                showsTimestamp: showsTimestamp
            )
        }
    }
}

/// The right-click menu, for the selection when the clicked row is in it and for that row alone when it isn't.
struct LibraryRowMenu: View {
    let model: AppModel
    let entries: [LibraryEntry]
    let rename: (LibraryEntry) -> Void
    let delete: (Set<LibraryEntry.ID>) -> Void

    private var ids: [LibraryEntry.ID] { entries.map(\.id) }

    /// A category every row already sits in isn't somewhere to move them.
    static func moveTargets(for entries: [LibraryEntry]) -> [EntryCategory] {
        let shared = Set(entries.map(\.category))
        return EntryCategory.allCases.filter { shared != [$0] }
    }

    var body: some View {
        if let entry = entries.first {
            if entries.count == 1 {
                single(entry)
            } else {
                several
            }
        }
    }

    @ViewBuilder
    private func single(_ entry: LibraryEntry) -> some View {
        Button("Open") {
            model.openEntryFromLibrary(entry.id, inNewWindow: false)
        }
        Button("Open in New Window") {
            model.openEntryWindow(entry.id)
        }
        .accessibilityIdentifier("library.row.\(entry.id).openInNewWindow")
        Divider()
        Button("Export…") {
            model.exportEntryFromLibrary(entry.id)
        }
        .accessibilityIdentifier("library.row.\(entry.id).export")
        share
        if model.destinationsEnabled {
            SendToMenu(model: model, entryID: entry.id)
                .accessibilityIdentifier("library.row.\(entry.id).sendTo")
        }
        Divider()
        pin
            .accessibilityIdentifier("library.row.\(entry.id).\(entry.pinned ? "unpin" : "pin")")
        Button("Rename…") {
            rename(entry)
        }
        .accessibilityIdentifier("library.row.\(entry.id).rename")
        move
            .accessibilityIdentifier("library.row.\(entry.id).moveTo")
        Divider()
        reveal
            .accessibilityIdentifier("library.row.\(entry.id).revealInFinder")
        Divider()
        Button("Delete", role: .destructive) {
            delete([entry.id])
        }
        .accessibilityIdentifier("library.row.\(entry.id).delete")
    }

    @ViewBuilder
    private var several: some View {
        Menu("Export") {
            ForEach(ExportFormat.allCases) { format in
                Button("\(format.displayName) (.\(format.fileExtension))") {
                    model.bulkExportEntries(ids: Set(ids), format: format)
                }
            }
        }
        share
        Divider()
        pin
        move
        Divider()
        reveal
        Divider()
        Button(role: .destructive) {
            delete(Set(ids))
        } label: {
            Text(verbatim: RecentlyDeletedCopy.deleteSelection(entries.count))
        }
    }

    private var share: some View {
        let files = entries.map { entry in
            LibraryEntryShareFile(
                title: LibraryEntryDisplay.listTitle(for: entry, showsAITitle: model.showAITitles), bundleURL: entry.bundleURL
            )
        }
        return ShareLink(items: files, preview: { SharePreview($0.title) })
    }

    private var pin: some View {
        let pins = LibraryRowsTarget.pins(entries)
        return Button(pins ? "Pin" : "Unpin") {
            model.setPinned(pins, for: ids)
        }
    }

    private var move: some View {
        Menu("Move to") {
            ForEach(Self.moveTargets(for: entries), id: \.self) { target in
                Button(LocalizedStringKey(libraryCategoryName(target))) {
                    model.moveEntries(ids, to: target)
                }
            }
        }
    }

    private var reveal: some View {
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting(entries.map(\.bundleURL))
        }
    }
}

/// Export and Delete for the rows a page has selected, in its header.
struct LibraryBulkActions: View {
    // Optional: AppKit can build a List cell after SwiftUI tore the List down, and a required read traps "No Observable object of type AppModel found".
    @Environment(AppModel.self) private var model: AppModel?
    @Binding var selection: Set<LibraryEntry.ID>
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
                        model?.bulkExportEntries(ids: selection, format: format)
                    }
                    .axLeaf("Header.MenuItem.Export\(format.rawValue.capitalized)")
                }
            } label: {
                Text("Export (\(selection.count))")
            }
            .libraryHeaderChip()
            .axLeaf("Header.Menu.BulkExport")
            Button {
                pendingBulkDelete = true
            } label: {
                Text(verbatim: RecentlyDeletedCopy.deleteSelection(selection.count))
                    .foregroundStyle(DS.Color.dangerText)
            }
            .libraryHeaderChip()
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
        model.deleteEntries(Array(targets))
    }

    private var isRenaming: Binding<Bool> {
        Binding(
            get: { renamingEntry != nil },
            set: { if !$0 { renamingEntry = nil } }
        )
    }
}
