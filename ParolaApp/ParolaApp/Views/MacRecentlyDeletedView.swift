import SwiftUI
import ParolaCore

struct MacRecentlyDeletedView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingPurge: LibraryEntry.ID?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.deletedEntries.isEmpty {
                empty
            } else {
                list
            }
        }
        .frame(minWidth: 520, minHeight: 360)
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
    }

    private var header: some View {
        HStack {
            Text("Recently Deleted").font(DS.Font.heading)
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(DS.Spacing.regular)
    }

    private var list: some View {
        VStack(spacing: 0) {
            List {
                ForEach(model.deletedEntries) { entry in
                    row(entry)
                }
            }
            footer
        }
    }

    private func row(_ entry: LibraryEntry) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).font(.body)
                if let deletedAt = entry.deletedAt {
                    Text(deletedAt, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                model.restoreEntry(entry.id)
            } label: {
                Label("Restore", systemImage: "arrow.uturn.backward.circle")
            }
            .buttonStyle(.bordered)
            Button(role: .destructive) {
                confirmingPurge = entry.id
            } label: {
                Label("Delete", systemImage: "trash")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 2)
    }

    private var footer: some View {
        Text("Items are removed for good after \(AppModel.trashRetentionDays) days.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(DS.Spacing.small)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var empty: some View {
        ContentUnavailableView(
            "Nothing's been deleted",
            systemImage: "trash",
            description: Text("Deleted transcripts appear here for \(AppModel.trashRetentionDays) days.")
        )
    }
}
