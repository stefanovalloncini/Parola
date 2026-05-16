import SwiftUI
import ParolaCore

struct RecentlyDeletedView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingPurge: LibraryEntry.ID?

    var body: some View {
        NavigationStack {
            Group {
                if model.deletedEntries.isEmpty {
                    empty
                } else {
                    List {
                        Section {
                            ForEach(model.deletedEntries) { entry in
                                row(entry)
                            }
                        } footer: {
                            Text("Items are removed for good after \(AppModel.trashRetentionDays) days.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Recently Deleted")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
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

    private func row(_ entry: LibraryEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.title).font(.body.weight(.medium))
            HStack(spacing: 8) {
                if let deletedAt = entry.deletedAt {
                    Text(deletedAt, style: .relative).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    model.restoreEntry(entry.id)
                } label: {
                    Label("Restore", systemImage: "arrow.uturn.backward.circle")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                Button(role: .destructive) {
                    confirmingPurge = entry.id
                } label: {
                    Label("Delete permanently", systemImage: "trash")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
            .font(.caption)
        }
        .padding(.vertical, 4)
    }

    private var empty: some View {
        ContentUnavailableView(
            "Nothing's been deleted",
            systemImage: "trash",
            description: Text("Deleted transcripts appear here for \(AppModel.trashRetentionDays) days.")
        )
    }
}
