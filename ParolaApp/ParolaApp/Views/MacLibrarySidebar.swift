import SwiftUI
import ParolaCore

struct MacLibrarySidebar: View {
    @EnvironmentObject var model: AppModel
    @State private var searchText = ""

    private var displayed: [LibraryEntry] {
        model.searchResults ?? model.libraryEntries
    }

    private var isSearching: Bool { model.searchResults != nil }

    var body: some View {
        List(selection: $model.selectedEntryID) {
            if displayed.isEmpty {
                Section {
                    Text(isSearching ? "No matches." : "Transcribe a file to start your library.")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.secondaryText)
                        .padding(.vertical, DS.Spacing.small)
                }
            } else {
                ForEach(EntryCategory.allCases, id: \.self) { category in
                    let entries = displayed.filter { $0.category == category }
                    if !entries.isEmpty {
                        Section(Self.label(for: category)) {
                            ForEach(entries) { entry in
                                row(entry).tag(entry.id)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Library")
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search transcripts")
        .onChange(of: searchText) { _, newValue in model.search(newValue) }
        .onChange(of: model.selectedEntryID) { _, newValue in
            if let id = newValue { model.loadEntry(id) }
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
