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

    /// A group's title, then its entries, in one run; an untitled group adds no title.
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

/// Whether the pointer is on one row. Each row watches a flag of its own, so a change touches the two rows involved and not every row on screen.
@MainActor
@Observable
final class RowHoverFlag {
    fileprivate(set) var isOn = false
}

/// Tracks the one row the pointer is on, so a row scrolled from under a still pointer lets go when the next one is entered.
@MainActor
@Observable
final class RowHover {
    @ObservationIgnored private var flags: [LibraryEntry.ID: RowHoverFlag] = [:]
    @ObservationIgnored private(set) var current: LibraryEntry.ID?

    func flag(for id: LibraryEntry.ID) -> RowHoverFlag {
        if let flag = flags[id] { return flag }
        let flag = RowHoverFlag()
        flags[id] = flag
        return flag
    }

    func enter(_ id: LibraryEntry.ID) {
        guard current != id else { return }
        if let previous = current { flags[previous]?.isOn = false }
        current = id
        flag(for: id).isOn = true
    }

    func leave(_ id: LibraryEntry.ID) {
        guard current == id else { return }
        flags[id]?.isOn = false
        current = nil
    }
}

/// A date group as the list's section: its title, which stays under the toolbar while the group scrolls, and its rows.
struct LibraryListSection: Identifiable, Equatable {
    let id: String
    let title: String?
    var rows: [LibraryRowDisplay]

    static func sections(for items: [LibraryListItem]) -> [LibraryListSection] {
        var sections: [LibraryListSection] = []
        for item in items {
            switch item {
            case .header(let id, let title):
                sections.append(LibraryListSection(id: id, title: title, rows: []))
            case .entry(let row):
                if sections.isEmpty { sections.append(LibraryListSection(id: "leading", title: nil, rows: [])) }
                sections[sections.count - 1].rows.append(row)
            }
        }
        return sections
    }
}

/// The rows of one library page, with their menu, drag and open gesture. Browsing and search results each own one.
struct LibraryRowList<Top: View>: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let items: [LibraryListItem]
    /// Taken once with the items, since a click re-runs the body and the rows animate on their ids alone.
    private let itemIDs: [String]
    private let sections: [LibraryListSection]
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
    /// Entries the page shows above the list, which a selection, a drag and the File menu reach like rows.
    var shelf: [LibraryRowDisplay] = []
    /// Set while the page's own title has scrolled out of sight, so the toolbar can carry a compact one.
    var titleScrolledAway: Binding<Bool>?
    /// Brings the shelf into view before the keyboard puts a selection on one of its tiles.
    var scrollToPageTop: (() -> Void)?
    @State private var hover = RowHover()
    /// The tile the keyboard is on; the list keeps the responder, and the arrows are read here while this is set.
    @State private var shelfCursor: LibraryEntry.ID?

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
        shelf: [LibraryRowDisplay] = [],
        titleScrolledAway: Binding<Bool>? = nil,
        scrollToPageTop: (() -> Void)? = nil,
        top: Top? = nil
    ) {
        self.items = items
        itemIDs = items.map(\.id)
        sections = LibraryListSection.sections(for: items)
        _selection = selection
        self.detail = detail
        self.animatesRows = animatesRows
        self.rename = rename
        _pendingBulkDelete = pendingBulkDelete
        self.focus = focus
        self.focusKey = focusKey
        self.rowAppeared = rowAppeared
        self.shelf = shelf
        self.titleScrolledAway = titleScrolledAway
        self.scrollToPageTop = scrollToPageTop
        self.top = top
    }

    /// List(.inset) indents its rows by 16 pt of its own; this lands a title on the 24 pt gutter.
    private static var titleInsets: EdgeInsets {
        EdgeInsets(top: 0, leading: DS.Spacing.small, bottom: 0, trailing: DS.Spacing.small)
    }

    /// The page title is gone once the list has moved about as far as the title is tall.
    private static var titleScrollThreshold: CGFloat { 56 }

    private func rows(of section: LibraryListSection) -> some View {
        ForEach(section.rows) { row in
            LibraryListRow(
                row: row,
                detail: detail,
                isSelected: selection.contains(row.id),
                rename: rename,
                delete: delete,
                menuEntries: menuEntries
            )
            .equatable()
            .onAppear { rowAppeared?(row.id) }
            // On the element, not in the row's body: behind `.equatable()` the list doesn't read them.
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
        }
    }

    /// The "…" menu acts on the selection when its row is part of it, as the right-click menu does.
    private func menuEntries(for entry: LibraryEntry) -> [LibraryEntry] {
        LibraryRowsTarget.menuEntries(for: entry, selection: selection, in: model.libraryEntries)
    }

    private var rowSelection: Binding<Set<LibraryEntry.ID>> {
        Binding(
            get: { selection },
            set: { selection = LibraryListItem.entries(in: $0, items: items) }
        )
    }

    var body: some View {
        List(selection: rowSelection) {
            if top != nil || !shelf.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    top
                    if !shelf.isEmpty {
                        RecentShelf(
                            rows: shelf,
                            selection: $selection,
                            cursor: shelfCursor,
                            rename: rename,
                            delete: delete,
                            choose: chooseTile
                        )
                    }
                }
                .listRowInsets(Self.titleInsets)
                .listRowSeparator(.hidden)
                .selectionDisabled()
                .id(LibraryListItem.pageTopID)
            }
            ForEach(sections) { section in
                if let title = section.title {
                    Section {
                        rows(of: section)
                    } header: {
                        LibraryGroupHeader(title: title)
                            .padding(.leading, DS.Spacing.small)
                    }
                } else {
                    rows(of: section)
                }
            }
        }
        .listStyle(.inset)
        .environment(hover)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top > Self.titleScrollThreshold
        } action: { _, scrolledAway in
            titleScrolledAway?.wrappedValue = scrolledAway
        }
        .readingColumn()
        .tint(DS.Color.accentFill)
        .focused(focus, equals: focusKey)
        .focusedValue(\.libraryRows, LibraryRowsTarget(
            entries: LibraryRowsTarget.selectedEntries(selection, in: items, shelf: shelf), rename: rename, delete: delete
        ))
        .onDeleteCommand(perform: deleteSelection)
        .background { ShelfKeyMonitor(isActive: !shelf.isEmpty && !model.hasSearchResults, handle: handle) }
        .onChange(of: selection) { _, new in
            if let cursor = shelfCursor, new != [cursor] { shelfCursor = nil }
        }
        .onChange(of: focus.wrappedValue) { old, new in
            if new != focusKey { shelfCursor = nil }
            guard new == focusKey, old != focusKey else { return }
            if selection.isEmpty, Self.isTab(NSApp.currentEvent), let first = shelf.first {
                scrollToPageTop?()
                chooseTile(first.id)
            } else {
                shelfCursor = RecentShelfRules.cursorToRestore(selection: selection, shelfIDs: shelf.map(\.id))
            }
        }
        .onChange(of: shelf.map(\.id)) { _, ids in
            if let cursor = shelfCursor, !ids.contains(cursor) { shelfCursor = nil }
        }
        .dragContainer(for: LibraryEntryDragItem.self) { ids in
            LibraryRowsTarget.selectedEntries(Set(ids), in: items, shelf: shelf).map {
                LibraryEntryDragItem(entry: $0, showsAITitle: model.showAITitles)
            }
        }
        .dragContainerSelection(Array(selection))
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

    /// `keyCode` raises on an event that isn't a key event, so the type is read first.
    private static func isTab(_ event: NSEvent?) -> Bool {
        guard let event, event.type == .keyDown || event.type == .keyUp else { return false }
        return event.keyCode == 48
    }

    private var firstRowID: LibraryEntry.ID? {
        items.lazy.compactMap { item -> LibraryEntry.ID? in
            if case .entry(let row) = item { return row.id }
            return nil
        }.first
    }

    private func chooseTile(_ id: LibraryEntry.ID) {
        selection = [id]
        shelfCursor = id
        focus.wrappedValue = focusKey
    }

    private func perform(_ action: RecentShelfRules.KeyAction) {
        switch action {
        case .none:
            break
        case .moveTo(let index):
            scrollToPageTop?()
            chooseTile(shelf[index].id)
        case .leaveForList:
            shelfCursor = nil
            if let first = firstRowID { selection = [first] }
        case .open(let index, let inNewWindow):
            RecentTile.open(shelf[index].id, inNewWindow: inNewWindow, in: model)
        case .delete(let index):
            delete([shelf[index].id])
        }
    }

    private func handle(_ key: RecentShelfRules.Key) -> Bool {
        let cursorIndex = shelfCursor.flatMap { id in shelf.firstIndex { $0.id == id } }
        let action = RecentShelfRules.action(
            for: key,
            cursor: cursorIndex,
            tileCount: shelf.count,
            firstRowIsOnlySelection: firstRowID.map { selection == [$0] } ?? false
        )
        perform(action)
        return action != .none
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

/// A date group's title, on the gutter the rows' badges start on; the list pins it under the toolbar while its group scrolls.
struct LibraryGroupHeader: View {
    let title: String

    var body: some View {
        Text(verbatim: title)
            .font(DS.Font.heading)
            .foregroundStyle(DS.Color.primaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, DS.Spacing.medium)
            .padding(.bottom, DS.Spacing.small)
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
    let delete: (Set<LibraryEntry.ID>) -> Void
    let menuEntries: (LibraryEntry) -> [LibraryEntry]
    @Environment(RowHover.self) private var hover: RowHover?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                if let model { LibraryRowActionButtons(model: model, entry: entry, rename: rename) }
            }
            .contentShape(Rectangle())
            .draggable(containerItemID: entry.id)
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

    private var isHovered: Bool { hover?.flag(for: row.id).isOn ?? false }

    @ViewBuilder
    private var rowContent: some View {
        switch detail {
        case .excerpt:
            EntryRow(
                display: row, detail: .excerpt(row.excerpt), isSelected: isSelected, hovered: isHovered,
                titleAccessory: AnyView(menuSlot),
                accessory: { EmptyView() },
                trailingActions: { EmptyView() }
            )
            .onHover { inside in
                if inside { hover?.enter(row.id) } else { hover?.leave(row.id) }
            }
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

extension LibraryListRow {
    /// Always there, so the date and duration keep their columns; the button fades in over it.
    private var menuSlot: some View {
        ZStack {
            if isHovered, let model {
                RowMenuButton(isSelected: isSelected) {
                    LibraryRowMenu(model: model, entries: menuEntries(row.entry), rename: rename, delete: delete)
                }
                .transition(.opacity)
            }
        }
        .frame(width: RowMenuSlot.width, height: RowMenuSlot.height)
        .animation(reduceMotion ? nil : DS.Motion.rowState, value: isHovered)
    }
}

/// The everyday actions of a row, as VoiceOver's Actions rotor offers them.
struct LibraryRowActionButtons: View {
    let model: AppModel
    let entry: LibraryEntry
    let rename: (LibraryEntry) -> Void

    var body: some View {
        Button("Open") { model.openEntryFromLibrary(entry.id, inNewWindow: false) }
        Button("Open in New Window") { model.openEntryWindow(entry.id) }
        Button("Export…") { model.exportEntryFromLibrary(entry.id) }
        Button(entry.pinned ? "Unpin" : "Pin") { model.togglePinned(for: entry.id) }
        Button("Rename…") { rename(entry) }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.bundleURL]) }
        Button("Delete") { model.deleteEntry(entry.id) }
    }
}

/// The room a row keeps on its title line for the menu button.
enum RowMenuSlot {
    static let width: CGFloat = 28
    static let height: CGFloat = 20
}

/// The row's own right-click menu, one click away while the pointer is over it.
struct RowMenuButton<Items: View>: View {
    let isSelected: Bool
    @ViewBuilder let items: () -> Items
    @Environment(\.backgroundProminence) private var backgroundProminence

    private var onAccent: Bool { DS.onAccent(isSelected: isSelected, prominence: backgroundProminence) }

    var body: some View {
        Menu(content: items) {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(onAccent ? DS.Color.onAccent : DS.Color.primaryText)
                .frame(width: RowMenuSlot.width, height: RowMenuSlot.height)
                .background(Capsule().fill(onAccent ? DS.Color.onAccentWash : DS.Palette.pillFill))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
        .accessibilityLabel("More")
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
    static func moveTargets(for entries: [LibraryEntry], features: FeatureSet) -> [EntryCategory] {
        let shared = Set(entries.map(\.category))
        return EntryCategory.shown(by: features).filter { shared != [$0] }
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

    @ViewBuilder
    private var move: some View {
        let targets = Self.moveTargets(for: entries, features: model.features)
        if !targets.isEmpty {
            Menu("Move to") {
                ForEach(targets, id: \.self) { target in
                    Button(LocalizedStringKey(libraryCategoryName(target))) {
                        model.moveEntries(ids, to: target)
                    }
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
                .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
