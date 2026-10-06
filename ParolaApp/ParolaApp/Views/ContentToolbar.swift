import SwiftUI
import ParolaCore

struct ContentToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        if let take = TakeTitleBar.take(on: model) {
            ToolbarItem(placement: .principal) {
                TakeTitleBar(take: take)
            }
            .sharedBackgroundVisibility(.hidden)
        }
        ToolbarSpacer(.flexible)
        if RecordControl.primarySource(features: model.features) != nil {
            // Its own item with no shared glass behind it, so the red capsule isn't set inside a second pill.
            ToolbarItem(placement: .primaryAction) {
                RecordControl()
            }
            .sharedBackgroundVisibility(.hidden)
        }
        ToolbarItem(placement: .primaryAction) {
            newMenu
        }
    }

    private var newMenu: some View {
        Menu {
            newMenuItems
        } label: {
            Label("New", systemImage: "plus")
        }
        .help("Start a new transcription.")
        .axLeaf("Toolbar.Menu.New")
    }

    /// Menus drop a Label's icon unless told otherwise; the toolbar button keeps its plain plus.
    private var newMenuItems: some View {
        Group {
            Button { model.presentOpenPanel() } label: { Label("Open Files…", systemImage: "folder") }
                .keyboardShortcut("o", modifiers: .command)
                .axLeaf("Toolbar.MenuItem.NewOpenFile")
            if model.features.isEnabled(.youtube) {
                Button { model.openLinkSheet(prefill: nil) } label: { Label("Transcribe Link…", systemImage: "link") }
                    .axLeaf("Toolbar.MenuItem.NewLink")
            }
            if model.features.isEnabled(.batch) {
                Button { model.presentBatchOpenPanel() } label: {
                    Label("Batch Transcribe…", systemImage: "square.stack.3d.up")
                }
                .axLeaf("Toolbar.MenuItem.NewBatch")
            }
        }
        .labelStyle(.titleAndIcon)
    }
}
