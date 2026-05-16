import SwiftUI
import ParolaCore

struct MacLibrarySidebar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List(selection: $model.selectedEntryID) {
            if model.libraryEntries.isEmpty {
                Section {
                    Text("Transcribe a file to start your library.")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.secondaryText)
                        .padding(.vertical, DS.Spacing.small)
                }
            } else {
                ForEach(model.libraryEntries) { entry in
                    row(entry).tag(entry.id)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Library")
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        .onChange(of: model.selectedEntryID) { _, newValue in
            if let id = newValue { model.loadEntry(id) }
        }
    }

    private func row(_ entry: LibraryEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.title).font(.body.weight(.medium)).lineLimit(2)
            HStack(spacing: 6) {
                Text(entry.createdAt, style: .date)
                Text("·")
                Text(entry.manifest.modelName).lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button(role: .destructive) {
                model.deleteEntry(entry.id)
            } label: {
                Label("Move to Recently Deleted", systemImage: "trash")
            }
        }
    }
}
