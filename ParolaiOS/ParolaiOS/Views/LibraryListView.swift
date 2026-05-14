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
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "waveform")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(Color.accentColor)
                .symbolEffect(.variableColor.iterative.reversing, options: .repeating, value: pulse)
                .shadow(color: Color.accentColor.opacity(0.18), radius: 18, x: 0, y: 6)
            VStack(spacing: 8) {
                Text("library.empty.title")
                    .font(.title3.weight(.semibold))
                Text("library.empty.body")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .onAppear { pulse = true }
    }
}
