import SwiftUI
import ParolaCore

struct MacRecentlyDeletedView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmingPurge: LibraryEntry.ID?
    @State private var confirmingPurgeBulk: Set<LibraryEntry.ID> = []
    @State private var confirmingEmpty = false
    @State private var searchText = ""
    @State private var categoryFilter: RecentlyDeletedCategoryFilter = .all
    @State private var sortOption: RecentlyDeletedSort = .deletedEarliest
    @State private var previews: [LibraryEntry.ID: String] = [:]
    @State private var rows: [LibraryRowDisplay] = []
    @State private var displayCache = LibraryRowDisplayCache()
    @State private var now = Date()
    @State private var groups: [BucketGroup] = []

    private var selection: Set<LibraryEntry.ID> { model.recentlyDeletedSelection }

    var body: some View {
        VStack(spacing: 0) {
            RecentlyDeletedHeader(
                categoryFilter: $categoryFilter,
                sortOption: $sortOption,
                confirmingEmpty: $confirmingEmpty,
                onRestoreSelection: { restore(Array(selection)) },
                onDeleteSelection: { confirmingPurgeBulk = selection }
            )
            Divider()
            if model.deletedEntries.isEmpty {
                empty
            } else if groups.isEmpty {
                noMatches
            } else {
                list
            }
        }
        .onChange(of: model.deletedEntries) { _, entries in
            let live = Set(entries.map(\.id))
            previews = previews.filter { live.contains($0.key) }
            model.recentlyDeletedSelection = model.recentlyDeletedSelection.intersection(live)
        }
        // Keyed on the entries so it runs on open and again whenever the trash changes.
        .task(id: model.deletedEntries) {
            now = Date()
            recomputeRows()
        }
        // One rebuild for the previews that arrived together, not one per row.
        .onChange(of: previews) { recomputeRows() }
        .onChange(of: model.showAITitles) { recomputeRows() }
        // The one input that moves with the active library, which nothing else on this page watches.
        .onChange(of: model.usualLanguage) { recomputeRows() }
        .onChange(of: searchText) { recomputeGroups() }
        .onChange(of: categoryFilter) { recomputeGroups() }
        .onChange(of: sortOption) { recomputeGroups() }
        .task(id: searchText.isEmpty ? "" : categoryFilter.rawValue) { await loadPreviewsForSearch() }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Color.surface)
        .toolbarSearch(text: $searchText, for: .recentlyDeleted)
        .background(RecentlyDeletedListMenusPublisher(sort: $sortOption, kind: $categoryFilter))
        .confirmationDialog(
            "Delete permanently?",
            isPresented: isPurgingSingle
        ) {
            Button("Delete Permanently", role: .destructive) {
                if let id = confirmingPurge { purge([id]) }
                confirmingPurge = nil
            }
            Button("Cancel", role: .cancel) { confirmingPurge = nil }
        } message: {
            Text("This can't be undone.")
        }
        .confirmationDialog(
            RecentlyDeletedCopy.bulkPurgeTitle(confirmingPurgeBulk.count),
            isPresented: isPurgingBulk
        ) {
            Button("Delete Permanently", role: .destructive) {
                purge(Array(confirmingPurgeBulk))
                confirmingPurgeBulk = []
            }
            Button("Cancel", role: .cancel) { confirmingPurgeBulk = [] }
        } message: {
            Text("This can't be undone.")
        }
        .confirmationDialog(
            "Delete all items now?",
            isPresented: $confirmingEmpty
        ) {
            Button("Delete All Now", role: .destructive) {
                purge(model.deletedEntries.map(\.id))
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(RecentlyDeletedCopy.emptyTrashMessage(model.deletedEntries.count))
        }
        // The headers and the countdown are written when the rows are built, so midnight has to rewrite them.
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            now = Date()
            recomputeRows()
        }
        // The one input no entry carries, so no row notices it changed on its own.
        .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in
            displayCache.removeAll()
            recomputeRows()
        }
        .axBranch("RecentlyDeleted")
    }

    private var list: some View {
        @Bindable var model = model
        return List(selection: $model.recentlyDeletedSelection) {
            ForEach(groups) { group in
                Section {
                    ForEach(group.rows) { row in
                        self.row(row)
                    }
                } header: {
                    sectionHeader(group)
                }
            }
        }
        .listStyle(.inset)
        .tint(DS.Color.accentFill)
        .onDeleteCommand(perform: confirmPurgeSelection)
        .animation(reduceMotion ? nil : DS.Motion.listRows, value: model.deletedEntries.map(\.id))
    }

    private func confirmPurgeSelection() {
        switch LibraryDeleteRequest.forSelection(count: selection.count) {
        case .none: break
        case .now: confirmingPurge = selection.first
        case .confirm: confirmingPurgeBulk = selection
        }
    }

    private func row(_ shown: ShownRow) -> some View {
        let display = shown.display
        let entry = display.entry
        return RecentlyDeletedRow(
            display: display,
            daysLeft: shown.daysLeft,
            timeLeft: shown.timeLeft,
            isSelected: selection.contains(entry.id),
            onRestore: { restore([entry.id]) },
            onPurge: { confirmingPurge = entry.id }
        )
        .listRowInsets(EdgeInsets(
            top: DS.Spacing.tight,
            leading: DS.Spacing.small,
            bottom: DS.Spacing.tight,
            trailing: DS.Spacing.small
        ))
        // The expiry bar is the rule between rows; the List's own would run three points under it.
        .listRowSeparator(.hidden)
        // Per row, so opening the page decodes what is on screen instead of the whole trash.
        .task(id: display.id) { await loadPreview(for: entry) }
    }

    @ViewBuilder
    private func sectionHeader(_ group: BucketGroup) -> some View {
        if let bucket = group.bucket {
            HStack(spacing: DS.Spacing.small) {
                SectionCaption(
                    LocalizedStringKey(bucket.caption),
                    tint: bucket == .soon ? DS.Color.dangerText : nil
                )
                Text(verbatim: AppFormat.integer(group.rows.count))
                    .font(DS.Font.caption)
                    .monospacedDigit()
                    .foregroundStyle(DS.Color.secondaryText)
            }
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

    private var empty: some View {
        EmptyStateView(
            systemImage: "trash",
            title: "Nothing's Been Deleted",
            message: "Deleted transcripts stay here for \(AppModel.trashRetentionDays) days, then they're removed for good."
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noMatches: some View {
        NoResultsView(systemImage: searchText.isEmpty ? "line.3.horizontal.decrease.circle" : "magnifyingglass") {
            searchText = ""
            categoryFilter = .all
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func recomputeGroups() {
        let shown = sortedRows().map { display in
            ShownRow(
                display: display,
                daysLeft: daysLeft(for: display.entry),
                timeLeft: RecentlyDeletedCopy.timeLeftLabel(
                    deletedAt: display.entry.deletedAt, now: now, retentionDays: AppModel.trashRetentionDays
                )
            )
        }
        guard sortOption.groupsByDate else {
            groups = shown.isEmpty ? [] : [BucketGroup(bucket: nil, rows: shown)]
            return
        }
        groups = RecentlyDeletedCopy.grouped(shown, daysLeft: \.daysLeft).map { BucketGroup(bucket: $0.bucket, rows: $0.items) }
    }

    private func sortedRows() -> [LibraryRowDisplay] {
        let filtered = rows.filter { row in
            categoryFilter.matches(row.entry.category)
                && RecentlyDeletedCopy.matches(query: searchText, title: row.title, preview: previews[row.id])
        }
        switch sortOption {
        case .recentlyDeleted:
            return filtered.sorted { lhs, rhs in
                (lhs.entry.deletedAt ?? .distantPast) > (rhs.entry.deletedAt ?? .distantPast)
            }
        case .deletedEarliest:
            return filtered.sorted { lhs, rhs in
                (lhs.entry.deletedAt ?? .distantFuture) < (rhs.entry.deletedAt ?? .distantFuture)
            }
        case .titleAZ:
            return filtered.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .titleZA:
            return filtered.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedDescending }
        }
    }

    private struct ShownRow: Identifiable {
        let display: LibraryRowDisplay
        let daysLeft: Int?
        let timeLeft: String
        var id: String { display.id }
    }

    private struct BucketGroup: Identifiable {
        let bucket: RecentlyDeletedCopy.ExpiryBucket?
        let rows: [ShownRow]
        var id: String { bucket?.rawValue ?? "" }
    }

    private func daysLeft(for entry: LibraryEntry) -> Int? {
        RecentlyDeletedCopy.daysLeft(
            deletedAt: entry.deletedAt,
            now: now,
            retentionDays: AppModel.trashRetentionDays
        )
    }

    private func restore(_ ids: [LibraryEntry.ID]) {
        model.restoreEntries(ids)
        model.recentlyDeletedSelection.subtract(ids)
    }

    private func purge(_ ids: [LibraryEntry.ID]) {
        for id in ids { model.purgeEntry(id) }
        model.recentlyDeletedSelection.subtract(ids)
    }

    private func loadPreview(for entry: LibraryEntry) async {
        if previews[entry.id] != nil { return }
        previews[entry.id] = RecentlyDeletedPreviews.preview(of: await readTranscriptText(at: entry.bundleURL))
    }

    /// Only the rows a filter keeps carry a preview task, so a search has to decode the rows it would otherwise never reach.
    private func loadPreviewsForSearch() async {
        guard !searchText.isEmpty else { return }
        let pending = model.deletedEntries.filter {
            previews[$0.id] == nil && categoryFilter.matches($0.category)
        }
        guard !pending.isEmpty else { return }
        await RecentlyDeletedPreviews.decode(pending) { entry in
            await readTranscriptText(at: entry.bundleURL)
        } publish: { decoded in
            previews.merge(decoded) { loaded, _ in loaded }
        }
    }

    private func recomputeRows() {
        var cache = displayCache
        cache.prune(keeping: model.deletedEntries.lazy.map(\.id))
        let usualLanguage = model.usualLanguage
        rows = model.deletedEntries.map { entry in
            cache.display(
                for: entry,
                excerpt: RecentlyDeletedRow.previewText(previews[entry.id]),
                when: RecentlyDeletedCopy.deletedOn(entry.deletedAt),
                usualLanguage: usualLanguage,
                showsAITitle: model.showAITitles
            )
        }
        displayCache = cache
        recomputeGroups()
    }

    private var isPurgingSingle: Binding<Bool> {
        Binding(
            get: { confirmingPurge != nil },
            set: { if !$0 { confirmingPurge = nil } }
        )
    }

    private var isPurgingBulk: Binding<Bool> {
        Binding(
            get: { !confirmingPurgeBulk.isEmpty },
            set: { if !$0 { confirmingPurgeBulk = [] } }
        )
    }
}

struct RecentlyDeletedListMenusPublisher: View {
    @Binding var sort: RecentlyDeletedSort
    @Binding var kind: RecentlyDeletedCategoryFilter

    var body: some View {
        Color.clear.focusedSceneValue(\.pageListMenus, .recentlyDeleted(sort: $sort, kind: $kind))
    }
}
