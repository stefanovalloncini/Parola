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
        if model.transcriptToolbarShows {
            TranscriptLeadingItems()
        }
        ToolbarSpacer(.flexible)
        if model.transcriptToolbarShows {
            TranscriptActionItems()
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
        if model.nowReadingLayout != .hidden {
            ToolbarItem(placement: .primaryAction) {
                NowReadingControl(layout: model.nowReadingLayout)
            }
            .keepsOutOfOverflow()
        }
        if RecordControl.primarySource(features: model.features) != nil {
            // Its own item with no shared glass behind it: Record and the capsule each wear their own.
            ToolbarItem(placement: .primaryAction) {
                RecordControl()
            }
            .sharedBackgroundVisibility(.hidden)
            .keepsOutOfOverflow()
        }
        ToolbarItem(placement: .primaryAction) {
            newMenu
        }
        .foldsFirst()
        if model.transcriptToolbarShows {
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                InspectorToolbarToggle()
            }
        }
    }

    private var newMenu: some View {
        Menu {
            NewMenuItems()
        } label: {
            Label("New", systemImage: "plus")
        }
        .help("Start a new transcription.")
        .axLeaf("Toolbar.Menu.New")
    }
}

/// The + menu's ways in; File repeats them under these same names.
enum NewMenuCommand {
    case openFiles
    case transcribeLink
    case addToQueue

    var title: LocalizedStringKey {
        switch self {
        case .openFiles: "Open Files…"
        case .transcribeLink: "Transcribe Link…"
        case .addToQueue: "Add to Queue…"
        }
    }

    var label: Label<Text, Image> {
        switch self {
        case .openFiles: Label(title, systemImage: DS.Symbol.openFiles)
        case .transcribeLink: Label(title, systemImage: "link")
        case .addToQueue: Label(title, systemImage: "square.stack.3d.up")
        }
    }
}

struct NewMenuItems: View {
    @Environment(AppModel.self) private var model

    /// Menus drop a Label's icon unless told otherwise; the toolbar button keeps its plain plus.
    var body: some View {
        Group {
            Button { model.presentOpenPanel() } label: { NewMenuCommand.openFiles.label }
                .keyboardShortcut("o", modifiers: .command)
                .axLeaf("Toolbar.MenuItem.NewOpenFile")
            if model.features.isEnabled(.youtube) {
                Button { model.openLinkSheet(prefill: nil) } label: { NewMenuCommand.transcribeLink.label }
                    .axLeaf("Toolbar.MenuItem.NewLink")
            }
            if model.features.isEnabled(.batch) {
                Button { model.presentBatchOpenPanel() } label: { NewMenuCommand.addToQueue.label }
                    .axLeaf("Toolbar.MenuItem.NewBatch")
            }
        }
        .labelStyle(.titleAndIcon)
    }
}

extension ToolbarContent {
    /// Folded into » first when the window is narrow; File repeats everything in +.
    @ToolbarContentBuilder
    func foldsFirst() -> some ToolbarContent {
        if #available(macOS 26.1, *) {
            visibilityPriority(.low)
        } else {
            self
        }
    }

    /// Folded into » last.
    @ToolbarContentBuilder
    func keepsOutOfOverflow() -> some ToolbarContent {
        if #available(macOS 26.1, *) {
            visibilityPriority(.high)
        } else {
            self
        }
    }
}
