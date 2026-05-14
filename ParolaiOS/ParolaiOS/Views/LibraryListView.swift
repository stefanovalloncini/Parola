import SwiftUI
import ParolaCore

struct LibraryListView: View {
    @EnvironmentObject var model: AppModel
    @Binding var selection: LibraryEntry.ID?

    var body: some View {
        Group {
            if model.libraryEntries.isEmpty {
                EmptyLibraryView()
            } else {
                List(selection: $selection) {
                    ForEach(model.libraryEntries) { entry in
                        NavigationLink(value: entry.id) {
                            row(entry)
                        }
                    }
                    .onDelete { offsets in
                        for offset in offsets {
                            model.deleteEntry(model.libraryEntries[offset].id)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private func row(_ entry: LibraryEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.title).font(.body.weight(.medium))
            HStack(spacing: 8) {
                Text(entry.createdAt, style: .date)
                Text("·")
                Text(entry.manifest.modelName)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct EmptyLibraryView: View {
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "waveform")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.secondary)
            Text("No transcripts yet")
                .font(.title3.weight(.semibold))
            Text("Tap + to import a file or record one.")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
