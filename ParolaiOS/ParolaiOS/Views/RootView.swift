import SwiftUI

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @State private var selectedEntry: LibraryEntry.ID?
    @State private var showingSettings = false
    @State private var showingNew = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                StatusBanner(phase: model.coordinator.phase)
                    .animation(.default, value: model.coordinator.phase)
                LibraryListView(selection: $selectedEntry)
            }
            .navigationTitle("Parola")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingNew = true } label: { Image(systemName: "plus") }
                }
            }
            .navigationDestination(for: LibraryEntry.ID.self) { id in
                TranscriptDetailView(entryID: id)
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsSheet().environmentObject(model)
        }
        .sheet(isPresented: $showingNew) {
            NewTranscriptionSheet().environmentObject(model)
        }
    }
}
