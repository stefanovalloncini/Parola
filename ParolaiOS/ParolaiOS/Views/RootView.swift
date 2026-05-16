import SwiftUI
import ParolaCore
import Combine

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var selectedEntry: LibraryEntry.ID?
    @State private var showingSettings = false
    @State private var showingNew = false
    @State private var showingTrash = false
    @State private var searchText = ""

    var body: some View {
        Group {
            if hSize == .regular {
                splitView
            } else {
                stackView
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsSheet()
        }
        .sheet(isPresented: $showingNew) {
            NewTranscriptionSheet()
        }
        .sheet(isPresented: $showingTrash) {
            RecentlyDeletedView()
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { model.lastError != nil },
                set: { if !$0 { model.lastError = nil } }
            ),
            presenting: model.lastError
        ) { _ in
            Button("OK", role: .cancel) { model.lastError = nil }
        } message: { error in
            Text(error)
        }
        .onReceive(NotificationCenter.default.publisher(for: .parolaOpenEntry)) { note in
            if let id = note.userInfo?["id"] as? String {
                selectedEntry = id
            }
        }
    }

    private var stackView: some View {
        NavigationStack {
            VStack(spacing: 0) {
                StatusBanner(phase: model.coordinator.phase)
                    .animation(.default, value: model.coordinator.phase)
                LibraryListView(selection: $selectedEntry)
            }
            .navigationTitle("Parola")
            .toolbar { toolbarItems }
            .searchable(text: $searchText, prompt: "Search transcripts")
            .onChange(of: searchText) { _, newValue in model.search(newValue) }
            .navigationDestination(item: $selectedEntry) { id in
                TranscriptDetailView(entryID: id)
            }
        }
    }

    private var splitView: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                StatusBanner(phase: model.coordinator.phase)
                    .animation(.default, value: model.coordinator.phase)
                LibraryListView(selection: $selectedEntry)
            }
            .navigationTitle("Parola")
            .toolbar { toolbarItems }
            .searchable(text: $searchText, prompt: "Search transcripts")
            .onChange(of: searchText) { _, newValue in model.search(newValue) }
        } detail: {
            if let id = selectedEntry {
                TranscriptDetailView(entryID: id)
            } else {
                ContentUnavailableView(
                    "root.picktranscript",
                    systemImage: "waveform",
                    description: Text("root.picktranscript.body")
                )
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { showingSettings = true } label: { Image(systemName: "gearshape") }
        }
        if !model.deletedEntries.isEmpty {
            ToolbarItem(placement: .topBarLeading) {
                Button { showingTrash = true } label: { Image(systemName: "trash") }
                    .accessibilityLabel(Text("Recently Deleted"))
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { showingNew = true } label: { Image(systemName: "plus") }
        }
    }
}
