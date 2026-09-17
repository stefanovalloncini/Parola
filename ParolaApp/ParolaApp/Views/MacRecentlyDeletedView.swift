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
    /// Built once per entry and per preview: the formatters behind a row are what this page loads n of.
    @State private var displays: [LibraryEntry.ID: LibraryRowDisplay] = [:]
    @State private var now = Date()

    private var selection: Set<LibraryEntry.ID> { model.recentlyDeletedSelection }

    var body: some View {
        VStack(spacing: 0) {
            RecentlyDeletedHeader(
                searchText: $searchText,
                categoryFilter: $categoryFilter,
                sortOption: $sortOption,
                confirmingEmpty: $confirmingEmpty,
                onRestoreSelection: { restore(Array(selection)) },
                onDeleteSelection: { confirmingPurgeBulk = selection }
            )
            Divider()
            if model.deletedEntries.isEmpty {
                empty
            } else if filtered.isEmpty {
                noMatches
            } else {
                list
            }
        }
        .onChange(of: model.deletedEntries) { _, entries in
            let live = Set(entries.map(\.id))
            previews = previews.filter { live.contains($0.key) }
            displays = displays.filter { live.contains($0.key) }
            model.recentlyDeletedSelection = model.recentlyDeletedSelection.intersection(live)
            for entry in entries { refreshDisplay(for: entry) }
            now = Date()
        }
        .task {
            now = Date()
            for entry in model.deletedEntries { await loadPreview(for: entry) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Color.surface)
        .tint(DS.Color.accent)
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
        .axBranch("RecentlyDeleted")
    }

    private var list: some View {
        @Bindable var model = model
        return List(selection: $model.recentlyDeletedSelection) {
            ForEach(sections) { group in
                Section {
                    ForEach(group.entries) { entry in
                        row(entry)
                    }
                } header: {
                    sectionHeader(group)
                }
            }
        }
        .listStyle(.inset)
        .tint(DS.Color.accent)
        .animation(reduceMotion ? nil : DS.Motion.listRows, value: model.deletedEntries.map(\.id))
    }

    private func row(_ entry: LibraryEntry) -> some View {
        RecentlyDeletedRow(
            display: displays[entry.id] ?? makeDisplay(for: entry),
            daysLeft: daysLeft(for: entry),
            timeLeft: timeLeft(for: entry),
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
        .task(id: entry.id) {
            await loadPreview(for: entry)
        }
    }

    @ViewBuilder
    private func sectionHeader(_ group: BucketGroup) -> some View {
        if let bucket = group.bucket {
            HStack(spacing: DS.Spacing.small) {
                SectionCaption(
                    LocalizedStringKey(bucket.caption),
                    tint: bucket == .soon ? DS.Color.dangerText : nil
                )
                Text(verbatim: AppFormat.integer(group.entries.count))
                    .font(DS.Font.caption)
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
        EmptyStateView(
            systemImage: searchText.isEmpty ? "line.3.horizontal.decrease.circle" : "magnifyingglass",
            title: noMatchesTitle,
            message: searchText.isEmpty ? "Try another kind of transcript." : nil
        ) {
            Button("Clear Filters") {
                searchText = ""
                categoryFilter = .all
            }
            .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
            .axLeaf("NoMatches.Button.ClearFilters")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noMatchesTitle: LocalizedStringKey {
        searchText.isEmpty ? "No Items Match These Filters" : "No Matches"
    }

    private var filtered: [LibraryEntry] {
        let q = searchText.lowercased()
        return model.deletedEntries.filter { entry in
            guard categoryFilter.matches(entry.category) else { return false }
            guard !q.isEmpty else { return true }
            if entry.title.lowercased().contains(q) { return true }
            return previews[entry.id]?.lowercased().contains(q) ?? false
        }
    }

    private var sorted: [LibraryEntry] {
        switch sortOption {
        case .recentlyDeleted:
            return filtered.sorted { lhs, rhs in
                (lhs.deletedAt ?? .distantPast) > (rhs.deletedAt ?? .distantPast)
            }
        case .deletedEarliest:
            return filtered.sorted { lhs, rhs in
                (lhs.deletedAt ?? .distantFuture) < (rhs.deletedAt ?? .distantFuture)
            }
        case .titleAZ:
            return filtered.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .titleZA:
            return filtered.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedDescending }
        }
    }

    private var sections: [BucketGroup] {
        guard sortOption.groupsByDate else { return [BucketGroup(bucket: nil, entries: sorted)] }
        return RecentlyDeletedCopy.grouped(sorted) { daysLeft(for: $0) }
            .map { BucketGroup(bucket: $0.bucket, entries: $0.items) }
    }

    private struct BucketGroup: Identifiable {
        let bucket: RecentlyDeletedCopy.ExpiryBucket?
        let entries: [LibraryEntry]
        var id: String { bucket?.rawValue ?? "" }
    }

    private func daysLeft(for entry: LibraryEntry) -> Int? {
        RecentlyDeletedCopy.daysLeft(
            deletedAt: entry.deletedAt,
            now: now,
            retentionDays: AppModel.trashRetentionDays
        )
    }

    private func timeLeft(for entry: LibraryEntry) -> String {
        RecentlyDeletedCopy.timeLeftLabel(
            deletedAt: entry.deletedAt,
            now: now,
            retentionDays: AppModel.trashRetentionDays
        )
    }

    private func restore(_ ids: [LibraryEntry.ID]) {
        for id in ids { model.restoreEntry(id) }
        model.recentlyDeletedSelection.subtract(ids)
    }

    private func purge(_ ids: [LibraryEntry.ID]) {
        for id in ids { model.purgeEntry(id) }
        model.recentlyDeletedSelection.subtract(ids)
    }

    private func loadPreview(for entry: LibraryEntry) async {
        if previews[entry.id] != nil { return }
        let text = await readTranscriptText(at: entry.bundleURL)
        let trimmed = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        previews[entry.id] = trimmed.isEmpty ? "" : String(trimmed.prefix(280))
        refreshDisplay(for: entry)
    }

    private func makeDisplay(for entry: LibraryEntry) -> LibraryRowDisplay {
        LibraryRowDisplay(
            entry: entry,
            excerpt: RecentlyDeletedRow.previewText(previews[entry.id]),
            date: entry.deletedAt,
            dateLabel: RecentlyDeletedCopy.deletedOn(entry.deletedAt)
        )
    }

    private func refreshDisplay(for entry: LibraryEntry) {
        let excerpt = RecentlyDeletedRow.previewText(previews[entry.id])
        if let cached = displays[entry.id], cached.excerpt == excerpt, cached.entry.manifest == entry.manifest {
            return
        }
        displays[entry.id] = makeDisplay(for: entry)
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
