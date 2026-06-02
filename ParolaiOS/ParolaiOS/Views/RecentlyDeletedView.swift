import SwiftUI
import ParolaCore

struct RecentlyDeletedView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingPurge: LibraryEntry.ID?
    @State private var searchText = ""
    @State private var sortOrder: SortOrder = .recentlyDeleted

    enum SortOrder: String, CaseIterable, Identifiable {
        case recentlyDeleted
        case deletedEarliest
        case titleAscending
        case titleDescending

        var id: String { rawValue }

        var label: String {
            switch self {
            case .recentlyDeleted: return "Recently deleted"
            case .deletedEarliest: return "Deleted earliest"
            case .titleAscending: return "Title A→Z"
            case .titleDescending: return "Title Z→A"
            }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.deletedEntries.isEmpty {
                    empty
                } else if visibleEntries.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    List {
                        Section {
                            ForEach(visibleEntries) { entry in
                                row(entry)
                            }
                        } footer: {
                            Text("Items are removed for good after \(AppModel.trashRetentionDays) days.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Recently Deleted")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sort", selection: $sortOrder) {
                            ForEach(SortOrder.allCases) { order in
                                Text(order.label).tag(order)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    .disabled(model.deletedEntries.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                "Delete permanently?",
                isPresented: Binding(
                    get: { confirmingPurge != nil },
                    set: { if !$0 { confirmingPurge = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete permanently", role: .destructive) {
                    if let id = confirmingPurge { model.purgeEntry(id) }
                    confirmingPurge = nil
                }
                Button("Cancel", role: .cancel) { confirmingPurge = nil }
            } message: {
                Text("This can't be undone.")
            }
        }
    }

    private var visibleEntries: [LibraryEntry] {
        let filtered: [LibraryEntry]
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            filtered = model.deletedEntries
        } else {
            let needle = trimmed.lowercased()
            filtered = model.deletedEntries.filter {
                $0.title.lowercased().contains(needle)
                    || Self.kindLabel(for: $0.category).lowercased().contains(needle)
                    || $0.manifest.modelName.lowercased().contains(needle)
            }
        }
        switch sortOrder {
        case .recentlyDeleted:
            return filtered.sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
        case .deletedEarliest:
            return filtered.sorted { ($0.deletedAt ?? .distantFuture) < ($1.deletedAt ?? .distantFuture) }
        case .titleAscending:
            return filtered.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .titleDescending:
            return filtered.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedDescending }
        }
    }

    private func row(_ entry: LibraryEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.title)
                .font(.body.weight(.medium))
            HStack(spacing: 6) {
                if let deletedAt = entry.deletedAt {
                    Text(deletedAt, style: .relative)
                    Text("·")
                }
                Text(Self.kindLabel(for: entry.category))
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.vertical, 6)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                model.restoreEntry(entry.id)
            } label: {
                Label("Restore", systemImage: "arrow.uturn.backward")
            }
            .tint(.blue)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                confirmingPurge = entry.id
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private static func kindLabel(for category: EntryCategory) -> String {
        switch category {
        case .transcription: return "Transcription"
        case .meeting: return "Meeting"
        case .dictation: return "Dictation"
        }
    }

    private var empty: some View {
        ContentUnavailableView(
            "Nothing's been deleted",
            systemImage: "trash",
            description: Text("Deleted transcripts appear here for \(AppModel.trashRetentionDays) days.")
        )
    }
}
