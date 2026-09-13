import SwiftUI
import ParolaCore

struct MacRecentlyDeletedView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmingPurge: LibraryEntry.ID?
    @State private var confirmingPurgeBulk: Set<LibraryEntry.ID> = []
    @State private var confirmingEmpty = false
    @State private var searchText = ""
    @State private var dateFilter: RecentlyDeletedDateFilter = .all
    @State private var categoryFilter: RecentlyDeletedCategoryFilter = .all
    @State private var sortOption: RecentlyDeletedSort = .deletedEarliest
    @State private var previews: [LibraryEntry.ID: String] = [:]
    /// Built once per entry and per preview: the formatters behind a row are what this page loads n of.
    @State private var displays: [LibraryEntry.ID: LibraryRowDisplay] = [:]
    @State private var selection: Set<LibraryEntry.ID> = []
    @State private var lastSelected: LibraryEntry.ID?
    @State private var purging: Set<LibraryEntry.ID> = []
    @State private var now = Date()

    var body: some View {
        VStack(spacing: 0) {
            RecentlyDeletedToolbar(
                searchText: $searchText,
                sortOption: $sortOption,
                confirmingEmpty: $confirmingEmpty,
                expiringSoon: expiringSoon,
                onDone: { dismiss() }
            )
            RecentlyDeletedFilterBar(
                dateFilter: $dateFilter,
                categoryFilter: $categoryFilter
            )
            Divider().opacity(0.5)
            if !selection.isEmpty {
                selectionBar
            }
            if model.deletedEntries.isEmpty {
                empty
            } else if filtered.isEmpty {
                noMatches
            } else {
                list
            }
            footer
        }
        .onChange(of: model.deletedEntries) { _, entries in
            let live = Set(entries.map(\.id))
            previews = previews.filter { live.contains($0.key) }
            displays = displays.filter { live.contains($0.key) }
            for entry in entries { refreshDisplay(for: entry) }
            now = Date()
        }
        .task {
            now = Date()
            for entry in model.deletedEntries { await loadPreview(for: entry) }
        }
        .frame(minWidth: 760, idealWidth: 920, minHeight: 560, idealHeight: 720)
        .background(DS.Color.surface)
        .tint(DS.Color.accent)
        .ignoresSafeArea(.container, edges: .top)
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
                selection = []
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

    private var selectionBar: some View {
        HStack(spacing: DS.Spacing.regular) {
            Text(RecentlyDeletedCopy.selectionCount(selection.count))
                .font(DS.Font.calloutEmphasized)
            Spacer()
            Button("Restore") { restore(Array(selection)) }
                .buttonStyle(DSPillButtonStyle(kind: .primary, size: .compact))
                .axLeaf("Selection.Button.Restore")
            Button("Delete Permanently") { confirmingPurgeBulk = selection }
                .buttonStyle(.plain)
                .font(DS.Font.subheadlineMedium)
                .foregroundStyle(DS.Color.dangerText)
                .axLeaf("Selection.Button.DeletePermanently")
            Button("Clear Selection") { selection = [] }
                .buttonStyle(.plain)
                .foregroundStyle(DS.Color.secondaryText)
                .axLeaf("Selection.Button.ClearSelection")
        }
        .padding(.horizontal, DS.Spacing.regular)
        .frame(height: 36)
        .background(DS.Color.surfaceElevated)
        .overlay(alignment: .bottom) { Divider().opacity(0.5) }
    }

    private var list: some View {
        let groups = sections
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.entries) { entry in
                            row(entry, isLast: entry.id == group.entries.last?.id)
                        }
                    } header: {
                        sectionHeader(group, isFirst: group.id == groups.first?.id)
                    }
                }
            }
            .padding(.horizontal, DS.Spacing.medium)
            .padding(.top, DS.Spacing.small)
            .padding(.bottom, DS.Spacing.medium)
            .animation(.easeOut(duration: 0.18), value: model.deletedEntries)
        }
    }

    private func row(_ entry: LibraryEntry, isLast: Bool) -> some View {
        RecentlyDeletedRow(
            display: displays[entry.id] ?? makeDisplay(for: entry),
            daysLeft: daysLeft(for: entry),
            timeLeft: timeLeft(for: entry),
            isSelected: selection.contains(entry.id),
            isPurging: purging.contains(entry.id),
            showsSeparator: !isLast,
            onRestore: { restore([entry.id]) },
            onPurge: { confirmingPurge = entry.id },
            onTap: { handleTap(entry: entry, modifiers: NSEvent.modifierFlags) }
        )
        .transition(rowTransition)
        .task(id: entry.id) {
            await loadPreview(for: entry)
        }
    }

    @ViewBuilder
    private func sectionHeader(_ group: BucketGroup, isFirst: Bool) -> some View {
        if let header = group.bucket.header {
            HStack(spacing: DS.Spacing.small) {
                SectionCaption(header, tint: group.bucket.tint)
                Rectangle()
                    .fill(DS.Color.separator.opacity(0.5))
                    .frame(height: 1)
                Text(verbatim: AppFormat.integer(group.entries.count))
                    .font(DS.Font.caption2Mono)
                    .foregroundStyle(DS.Color.secondaryText)
            }
            .padding(.vertical, DS.Spacing.tight)
            .padding(.top, isFirst ? 0 : DS.Spacing.large)
            .background(DS.Color.surface)
        }
    }

    private var footer: some View {
        HStack(spacing: DS.Spacing.regular) {
            Text("Items are removed for good after \(AppModel.trashRetentionDays) days.")
                .font(DS.Font.secondary)
                .foregroundStyle(DS.Color.secondaryText)
            Spacer(minLength: DS.Spacing.regular)
            Button("Delete All Now", role: .destructive) { confirmingEmpty = true }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(model.deletedEntries.isEmpty)
                .help("Delete every item in Recently Deleted")
                .axLeaf("Toolbar.Button.EmptyTrash")
        }
        .padding(.horizontal, DS.Spacing.regular)
        .padding(.vertical, DS.Spacing.small)
        .background(DS.Color.surface)
        .overlay(alignment: .top) { Divider().opacity(0.5) }
    }

    private var empty: some View {
        VStack(spacing: DS.Spacing.large) {
            DecayStrip(
                daysRemaining: 0,
                totalDays: AppModel.trashRetentionDays,
                seed: "",
                liveColor: DS.Color.separator.opacity(0.55),
                barWidth: 3,
                spacing: 3,
                height: 28,
                collapsed: true
            )
            VStack(spacing: DS.Spacing.small) {
                Text("Nothing's Been Deleted")
                    .font(DS.Font.title3)
                    .foregroundStyle(DS.Color.primaryText)
                Text("Deleted transcripts stay here for \(AppModel.trashRetentionDays) days, then they're removed for good.")
                    .font(DS.Font.callout)
                    .foregroundStyle(DS.Color.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noMatches: some View {
        VStack(spacing: DS.Spacing.large) {
            Image(systemName: searchText.isEmpty ? "line.3.horizontal.decrease.circle" : "magnifyingglass")
                .font(DS.Font.largeTitle)
                .imageScale(.large)
                .foregroundStyle(DS.Color.secondaryText.opacity(0.5))
            VStack(spacing: DS.Spacing.small) {
                Text(noMatchesTitle)
                    .font(DS.Font.title3)
                    .foregroundStyle(DS.Color.primaryText)
                if searchText.isEmpty {
                    Text("Try a different When or Kind filter.")
                        .font(DS.Font.callout)
                        .foregroundStyle(DS.Color.secondaryText)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                }
            }
            Button("Clear Filters") {
                searchText = ""
                dateFilter = .all
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
            guard dateFilter.matches(entry.deletedAt, now: now) else { return false }
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
        guard sortOption.groupsByDate else { return [BucketGroup(bucket: .none, entries: sorted)] }
        var seen = Set<String>()
        var order: [Bucket] = []
        var bucketed: [String: [LibraryEntry]] = [:]
        for entry in sorted {
            let key = bucket(for: entry)
            if seen.insert(key.id).inserted { order.append(key) }
            bucketed[key.id, default: []].append(entry)
        }
        return order.map { BucketGroup(bucket: $0, entries: bucketed[$0.id] ?? []) }
    }

    private struct BucketGroup: Identifiable {
        let bucket: Bucket
        let entries: [LibraryEntry]
        var id: String { bucket.id }
    }

    enum Bucket {
        case none
        case overdue
        case critical
        case soon
        case calm
        case undated

        var id: String {
            switch self {
            case .none: return ""
            case .overdue: return "overdue"
            case .critical: return "critical"
            case .soon: return "soon"
            case .calm: return "calm"
            case .undated: return "undated"
            }
        }

        var header: Text? {
            switch self {
            case .none: return nil
            case .overdue: return Text("Past deadline")
            case .critical: return Text("Final 48 hours")
            case .soon: return Text("Expiring this week")
            case .calm: return Text("Expiring later")
            case .undated: return Text("No deadline")
            }
        }

        var tier: RecentlyDeletedCopy.Tier? {
            switch self {
            case .none: return nil
            case .overdue: return .overdue
            case .critical: return .critical
            case .soon: return .soon
            case .calm: return .calm
            case .undated: return .undated
            }
        }

        var tint: Color { tier?.color ?? DS.Color.secondaryText }
    }

    private func bucket(for entry: LibraryEntry) -> Bucket {
        switch RecentlyDeletedCopy.tier(daysLeft: daysLeft(for: entry)) {
        case .overdue: return .overdue
        case .critical: return .critical
        case .soon: return .soon
        case .calm: return .calm
        case .undated: return .undated
        }
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

    private var expiringSoon: Int {
        model.deletedEntries.filter { entry in
            guard let days = daysLeft(for: entry) else { return false }
            return days <= 2
        }.count
    }

    private var rowTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .leading))
    }

    private func restore(_ ids: [LibraryEntry.ID]) {
        for id in ids { model.restoreEntry(id) }
        selection.subtract(ids)
    }

    // The strip has to finish flatlining before the entry goes, so the purge waits out the animation.
    private func purge(_ ids: [LibraryEntry.ID]) {
        guard !reduceMotion else {
            for id in ids { model.purgeEntry(id) }
            return
        }
        withAnimation(.easeOut(duration: 0.18)) { purging.formUnion(ids) }
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            for id in ids { model.purgeEntry(id) }
            purging.subtract(ids)
        }
    }

    private func handleTap(entry: LibraryEntry, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            toggle(entry.id)
            lastSelected = entry.id
            return
        }
        if modifiers.contains(.shift), let anchor = lastSelected {
            extendSelection(from: anchor, to: entry.id)
            return
        }
        if !selection.isEmpty {
            selection = [entry.id]
            lastSelected = entry.id
            return
        }
        model.loadEntry(entry.id)
    }

    private func toggle(_ id: LibraryEntry.ID) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }

    private func extendSelection(from anchor: LibraryEntry.ID, to current: LibraryEntry.ID) {
        let ordered = sorted
        guard let a = ordered.firstIndex(where: { $0.id == anchor }),
              let b = ordered.firstIndex(where: { $0.id == current }) else { return }
        let range = (min(a, b)...max(a, b)).map { ordered[$0].id }
        selection.formUnion(range)
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

    /// The row states the date it was deleted: on this page the creation date is the less useful of the two.
    private func makeDisplay(for entry: LibraryEntry) -> LibraryRowDisplay {
        LibraryRowDisplay(
            entry: entry,
            sizeBytes: nil,
            excerpt: RecentlyDeletedRow.previewText(previews[entry.id]),
            date: entry.deletedAt
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
