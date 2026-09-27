import SwiftUI
import ParolaCore

/// The results of a library query, in a list of their own: a keystroke re-ranks these rows and never the browse list's.
struct LibrarySearchResults: View {
    /// Rows are realised a page at a time, so a broad prefix hands the list a few dozen rows to diff, not the library.
    static let pageSize = 50
    /// How close to the last realised row the next page is fetched, so scrolling never reaches the end first.
    static let pageLead = 15

    @Environment(AppModel.self) private var model
    let ranking: [LibraryEntry.ID]
    let focus: FocusState<LibraryListFocus?>.Binding

    @State private var selection: Set<LibraryEntry.ID> = []
    @State private var pendingBulkDelete = false
    @State private var renamingEntry: LibraryEntry?
    @State private var renameDraft: String = ""
    @State private var resultIDs: [LibraryEntry.ID] = []
    @State private var rows: [LibraryRowDisplay] = []
    @State private var groups: [LibraryDateGroups.Group] = []
    @State private var shownCount = LibrarySearchResults.pageSize
    @State private var shownQuery = ""
    @State private var displayCache = LibraryRowDisplayCache()
    @State private var animatesRows = false

    /// True once a row within a lead's distance of the last realised one is on screen and more results wait.
    static func wantsNextPage(appearedAt index: Int, shown: Int, total: Int) -> Bool {
        total > shown && index >= shown - pageLead
    }

    private func recompute() {
        let resolved = ranking.compactMap { model.libraryEntry(id: $0) }
        var cache = displayCache
        cache.prune(keeping: ranking)
        let displays = resolved.prefix(shownCount).map {
            cache.display(
                for: $0, excerpt: nil,
                showsAITitle: model.showAITitles, showsAISummary: model.showAISummaries
            )
        }
        displayCache = cache
        resultIDs = resolved.map(\.id)
        rows = displays
        groups = LibraryListContent.groups(for: displays, sortOrder: model.librarySortOrder, isSearchResult: true)
        selection.formIntersection(Set(displays.map(\.id)))
        model.fillSearchSnippets(for: displays.map(\.id))
    }

    /// Any row near the end counts, not one fixed row: a jump to the end can realise the last rows and skip the ones before.
    private func rowAppeared(_ id: LibraryEntry.ID) {
        guard let index = rows.firstIndex(where: { $0.id == id }),
              Self.wantsNextPage(appearedAt: index, shown: rows.count, total: resultIDs.count) else { return }
        shownCount = rows.count + Self.pageSize
        recompute()
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if rows.isEmpty {
                emptyState
            } else {
                LibraryRowList(
                    groups: groups,
                    selection: $selection,
                    // Read over every result, not the realised rows, so the column doesn't jump as pages land.
                    detail: .match(showsTimestamp: LibraryListContent.showsTimestampSlot(
                        for: resultIDs, matches: model.searchMatches
                    )),
                    animatesRows: animatesRows,
                    rename: { entry in
                        renameDraft = LibraryEntryDisplay.title(for: entry)
                        renamingEntry = entry
                    },
                    focus: focus,
                    focusKey: .results,
                    rowAppeared: rowAppeared
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            shownQuery = model.searchQuery
            recompute()
        }
        .task { animatesRows = true }
        // A new query starts from the first page; the same query re-ranked after a library change keeps the pages it had.
        .onChange(of: ranking) { _, _ in
            if model.searchQuery != shownQuery {
                shownQuery = model.searchQuery
                shownCount = Self.pageSize
            }
            recompute()
        }
        .onChange(of: model.libraryVersion) { _, _ in recompute() }
        .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in
            displayCache.removeAll()
            recompute()
        }
        .modifier(LibraryListAlerts(
            selection: $selection,
            pendingBulkDelete: $pendingBulkDelete,
            renamingEntry: $renamingEntry,
            renameDraft: $renameDraft
        ))
    }

    private var queryText: String {
        model.searchQuery.trimmingCharacters(in: .whitespaces)
    }

    private var title: LocalizedStringKey {
        queryText.isEmpty ? "Search results" : "Results for “\(queryText)”"
    }

    private var header: some View {
        PageHeader(
            title: title,
            // Computed, not stored: the entry set can stay put while a query edit changes how often each one matches.
            subtitle: LibraryListContent.searchTotalsLabel(for: resultIDs, matches: model.searchMatches),
            leading: { EmptyView() },
            trailing: { LibraryBulkActions(selection: selection, pendingBulkDelete: $pendingBulkDelete) }
        )
    }

    private var emptyState: some View {
        EmptyStateView(
            systemImage: "magnifyingglass",
            title: "No results for “\(queryText)”",
            message: "Search looks in titles and transcript text"
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
