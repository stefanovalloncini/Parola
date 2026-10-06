import SwiftUI
import ParolaCore

/// View ▸ Go: every sidebar page, and Statistics, with a key each; ⌘1–3 belong to the transcript's panes.
struct GoCommands: View {
    let model: AppModel

    var body: some View {
        Section("Go") {
            Button("Library") { model.goHome() }
                .keyboardShortcut("1", modifiers: [.command, .option])
                .axLeaf("Menu.View.Go.Library")
            Button("Transcriptions") { model.browseCategory(.transcription) }
                .keyboardShortcut("2", modifiers: [.command, .option])
                .axLeaf("Menu.View.Go.Transcriptions")
            if model.features.isEnabled(.meetings) {
                Button("Meetings") { model.browseCategory(.meeting) }
                    .keyboardShortcut("3", modifiers: [.command, .option])
                    .axLeaf("Menu.View.Go.Meetings")
            }
            if model.features.isEnabled(.dictation) {
                Button("Dictations") { model.browseCategory(.dictation) }
                    .keyboardShortcut("4", modifiers: [.command, .option])
                    .axLeaf("Menu.View.Go.Dictations")
            }
            Button("Queue") { model.openQueue() }
                .keyboardShortcut("5", modifiers: [.command, .option])
                .disabled(!model.sidebarShowsActivity)
                .axLeaf("Menu.View.Go.Activity")
            Button("Recently Deleted") { model.openRecentlyDeleted() }
                .keyboardShortcut("6", modifiers: [.command, .option])
                .axLeaf("Menu.View.Go.RecentlyDeleted")
            Button("Statistics") { model.openStatistics() }
                .keyboardShortcut("7", modifiers: [.command, .option])
                .axLeaf("Menu.View.Statistics")
        }
        .disabled(model.introduction.isPresented)
    }
}
