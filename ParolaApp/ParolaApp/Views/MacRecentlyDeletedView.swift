import SwiftUI
import ParolaCore

struct MacRecentlyDeletedView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingPurge: LibraryEntry.ID?
    @State private var confirmingEmpty = false
    @State private var searchText = ""
    @State private var dateFilter: RecentlyDeletedDateFilter = .all
    @State private var categoryFilter: RecentlyDeletedCategoryFilter = .all
    @State private var sortOption: RecentlyDeletedSort = .recentlyDeleted
    @State private var previews: [LibraryEntry.ID: String] = [:]

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
            Divider().opacity(0.5)
            if model.deletedEntries.isEmpty {
                empty
            } else if filtered.isEmpty {
                noMatches
            } else {
                list
            }
        }
        .frame(minWidth: 620, minHeight: 460)
        .background(DS.Color.surface)
        .confirmationDialog(
            "Delete permanently?",
            isPresented: Binding(
                get: { confirmingPurge != nil },
                set: { if !$0 { confirmingPurge = nil } }
            )
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
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DS.Spacing.large, pinnedViews: []) {
                ForEach(sections, id: \.0) { group in
                    section(title: group.0, entries: group.1)
                }
                footer
            }
            .padding(.horizontal, DS.Spacing.regular)
            .padding(.top, DS.Spacing.regular)
            .padding(.bottom, DS.Spacing.small)
        }
    }

    private func section(title: String, entries: [LibraryEntry]) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            if !title.isEmpty {
                Text(title.uppercased())
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
                        onRestore: { model.restoreEntry(entry.id) },
                        onPurge: { confirmingPurge = entry.id },
                        onTap: { model.loadEntry(entry.id) }
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

    private var noMatches: some View {
        ContentUnavailableView.search(text: searchText)
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

    private var sections: [(String, [LibraryEntry])] {
        guard sortOption.groupsByDate else { return [("", sorted)] }
        var seen = Set<String>()
        var order: [String] = []
        var bucketed: [String: [LibraryEntry]] = [:]
        for entry in sorted {
            let key = bucket(for: entry.deletedAt)
            if seen.insert(key).inserted { order.append(key) }
            bucketed[key, default: []].append(entry)
        }
        return order.map { ($0, bucketed[$0] ?? []) }
    }

    private func bucket(for date: Date?) -> String {
        guard let date else { return "Unknown" }
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: Date())).day ?? 0
        if days < 7 { return "Earlier This Week" }
        if days < 30 { return "Earlier This Month" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: date)
    }

    private func loadPreview(for entry: LibraryEntry) async {
        if previews[entry.id] != nil { return }
        let text = await Task.detached { () -> String in
            let bundleURL = entry.bundleURL
            let transcriptURL = bundleURL.appendingPathComponent("transcript.json")
            guard let data = try? Data(contentsOf: transcriptURL),
                  let transcript = try? JSONDecoder().decode(Transcript.self, from: data)
            else { return "" }
            return transcript.text
        }.value
        let trimmed = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        previews[entry.id] = trimmed.isEmpty ? "" : String(trimmed.prefix(280))
    }
}

private extension RecentlyDeletedDateFilter {
    func matches(_ deletedAt: Date?, now: Date) -> Bool {
        guard self != .all else { return true }
        guard let deletedAt else { return self == .older }
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: deletedAt), to: cal.startOfDay(for: now)).day ?? 0
        switch self {
        case .all: return true
        case .today: return cal.isDateInToday(deletedAt)
        case .week: return days < 7
        case .month: return days < 30
        case .older: return days >= 30
        }
    }
}
