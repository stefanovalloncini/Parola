import SwiftUI
import ParolaCore

struct LibraryListView: View {
    @EnvironmentObject var model: AppModel
    @Binding var selection: LibraryEntry.ID?

    private var displayed: [LibraryEntry] {
        model.searchResults ?? model.libraryEntries
    }

    private var isSearching: Bool { model.searchResults != nil }

    var body: some View {
        Group {
            if displayed.isEmpty {
                if isSearching {
                    ContentUnavailableView.search
                } else {
                    EmptyLibraryView()
                }
            } else {
                List(selection: $selection) {
                    ForEach(EntryCategory.allCases, id: \.self) { category in
                        let entries = displayed.filter { $0.category == category }
                        if !entries.isEmpty {
                            Section(Self.label(for: category)) {
                                ForEach(entries) { entry in
                                    row(entry).tag(entry.id)
                                }
                                .onDelete { offsets in
                                    let ids = offsets.map { entries[$0].id }
                                    for id in ids { model.deleteEntry(id) }
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private static func label(for category: EntryCategory) -> String {
        switch category {
        case .transcription: return "Transcriptions"
        case .meeting: return "Meetings"
        case .dictation: return "Dictations"
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
