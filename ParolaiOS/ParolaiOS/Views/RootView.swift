import SwiftUI

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var selectedEntry: LibraryEntry.ID?
    @State private var showingSettings = false
    @State private var showingNew = false

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
        ToolbarItem(placement: .topBarTrailing) {
            Button { showingNew = true } label: { Image(systemName: "plus") }
        }
    }
}
