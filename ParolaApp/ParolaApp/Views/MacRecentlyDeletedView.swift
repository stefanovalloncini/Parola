import SwiftUI
import ParolaCore

struct MacRecentlyDeletedView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingPurge: LibraryEntry.ID?
    @State private var confirmingPurgeBulk: Set<LibraryEntry.ID> = []
    @State private var confirmingEmpty = false
    @State private var searchText = ""
    @State private var dateFilter: RecentlyDeletedDateFilter = .all
    @State private var categoryFilter: RecentlyDeletedCategoryFilter = .all
    @State private var sortOption: RecentlyDeletedSort = .recentlyDeleted
    @State private var previews: [LibraryEntry.ID: String] = [:]
    @State private var selection: Set<LibraryEntry.ID> = []
    @State private var lastSelected: LibraryEntry.ID?

    var body: some View {
        VStack(spacing: 0) {
            RecentlyDeletedToolbar(
                searchText: $searchText,
                sortOption: $sortOption,
                confirmingEmpty: $confirmingEmpty,
                onDone: { dismiss() }
            )
            RecentlyDeletedFilterBar(
                dateFilter: $dateFilter,
                categoryFilter: $categoryFilter
            )
            if !selection.isEmpty {
                selectionBar
            }
            Divider().opacity(0.5)
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
        }
        .task {
            for entry in model.deletedEntries { await loadPreview(for: entry) }
        }
        .frame(minWidth: 640, idealWidth: 820, minHeight: 520, idealHeight: 680)
        .background(DS.Color.surface)
        .ignoresSafeArea(.container, edges: .top)
        .confirmationDialog(
            "Delete permanently?",
            isPresented: isPurgingSingle
        ) {
            Button("Delete permanently", role: .destructive) {
                if let id = confirmingPurge { model.purgeEntry(id) }
                confirmingPurge = nil
            }
            Button("Cancel", role: .cancel) { confirmingPurge = nil }
        } message: {
            Text("This can't be undone.")
        }
        .confirmationDialog(
            "Delete \(confirmingPurgeBulk.count) items permanently?",
            isPresented: isPurgingBulk
        ) {
            Button("Delete permanently", role: .destructive) {
                for id in confirmingPurgeBulk { model.purgeEntry(id) }
                confirmingPurgeBulk = []
                selection = []
            }
            Button("Cancel", role: .cancel) { confirmingPurgeBulk = [] }
        } message: {
            Text("This can't be undone.")
        }
        .confirmationDialog(
            "Empty Recently Deleted?",
            isPresented: $confirmingEmpty
        ) {
            Button("Empty", role: .destructive) {
                for entry in model.deletedEntries { model.purgeEntry(entry.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All \(model.deletedEntries.count) items will be deleted for good.")
        }
        .axBranch("RecentlyDeleted")
    }

    private var selectionBar: some View {
        HStack(spacing: DS.Spacing.regular) {
            Text("\(selection.count) selected")
                .font(DS.Font.body.weight(.medium))
            Spacer()
            Button {
                for id in selection { model.restoreEntry(id) }
                selection = []
            } label: {
                Label("Restore", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(.bordered)
            .axLeaf("Selection.Button.Restore")
            Button(role: .destructive) {
                confirmingPurgeBulk = selection
            } label: {
                Label("Delete permanently", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .axLeaf("Selection.Button.DeletePermanently")
            Button("Clear selection") { selection = [] }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .axLeaf("Selection.Button.ClearSelection")
        }
        .padding(.horizontal, DS.Spacing.regular)
        .padding(.vertical, DS.Spacing.small)
        .background(DS.Color.surfaceElevated)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DS.Spacing.large, pinnedViews: []) {
                ForEach(sections, id: \.0.id) { group in
                    section(bucket: group.0, entries: group.1)
                }
                footer
            }
            .padding(.horizontal, DS.Spacing.regular)
            .padding(.top, DS.Spacing.regular)
            .padding(.bottom, DS.Spacing.small)
        }
    }

    private func section(bucket: Bucket, entries: [LibraryEntry]) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            if let header = bucket.header {
                header
                    .textCase(.uppercase)
                    .font(.system(.caption, design: .default, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
            VStack(spacing: DS.Spacing.small) {
                ForEach(entries) { entry in
                    RecentlyDeletedRow(
                        entry: entry,
                        preview: previews[entry.id],
                        isSelected: selection.contains(entry.id),
                        onRestore: { model.restoreEntry(entry.id) },
                        onPurge: { confirmingPurge = entry.id },
                        onTap: { handleTap(entry: entry, modifiers: NSEvent.modifierFlags) }
                    )
                    .task(id: entry.id) {
                        await loadPreview(for: entry)
                    }
                }
            }
        }
    }

    private var footer: some View {
        Text("Items are removed for good after \(AppModel.trashRetentionDays) days.")
            .font(DS.Font.caption)
            .foregroundStyle(.secondary)
            .padding(.top, DS.Spacing.small)
            .padding(.leading, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var empty: some View {
        ContentUnavailableView(
            "Nothing's been deleted",
            systemImage: "trash",
            description: Text("Deleted transcripts appear here for \(AppModel.trashRetentionDays) days.")
        )
    }

    @ViewBuilder
    private var noMatches: some View {
        if searchText.isEmpty {
            ContentUnavailableView(
                "No items match these filters",
                systemImage: "line.3.horizontal.decrease.circle",
                description: Text("Try a different When or Kind filter.")
            )
        } else {
            ContentUnavailableView.search(text: searchText)
        }
    }

    private var filtered: [LibraryEntry] {
        let q = searchText.lowercased()
        return model.deletedEntries.filter { entry in
            guard categoryFilter.matches(entry.category) else { return false }
            guard dateFilter.matches(entry.deletedAt, now: Date()) else { return false }
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

    private var sections: [(Bucket, [LibraryEntry])] {
        guard sortOption.groupsByDate else { return [(.none, sorted)] }
        var seen = Set<String>()
        var order: [Bucket] = []
        var bucketed: [String: [LibraryEntry]] = [:]
        for entry in sorted {
            let key = bucket(for: entry.deletedAt)
            if seen.insert(key.id).inserted { order.append(key) }
            bucketed[key.id, default: []].append(entry)
        }
        return order.map { ($0, bucketed[$0.id] ?? []) }
    }

    private enum Bucket {
        case none
        case today
        case yesterday
        case earlierThisWeek
        case earlierThisMonth
        case month(String)
        case unknown

        var id: String {
            switch self {
            case .none: return ""
            case .today: return "today"
            case .yesterday: return "yesterday"
            case .earlierThisWeek: return "earlierThisWeek"
            case .earlierThisMonth: return "earlierThisMonth"
            case .month(let label): return label
            case .unknown: return "unknown"
            }
        }

        var header: Text? {
            switch self {
            case .none: return nil
            case .today: return Text("Today")
            case .yesterday: return Text("Yesterday")
            case .earlierThisWeek: return Text("Earlier This Week")
            case .earlierThisMonth: return Text("Earlier This Month")
            case .month(let label): return Text(verbatim: label)
            case .unknown: return Text("Unknown")
            }
        }
    }

    private func bucket(for date: Date?) -> Bucket {
        guard let date else { return .unknown }
        let cal = Calendar.current
        if cal.isDateInToday(date) { return .today }
        if cal.isDateInYesterday(date) { return .yesterday }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: Date())).day ?? 0
        if days < 7 { return .earlierThisWeek }
        if days < 30 { return .earlierThisMonth }
        return .month(date.formatted(.dateTime.month(.wide).year()))
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

