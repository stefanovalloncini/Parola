import SwiftUI
import ParolaCore

struct ContentToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
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
        .disabled(isBusy)
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

    private var isBusy: Bool {
        switch model.phase {
        case .idle, .ready, .failed: return false
        default: return true
        }
    }
}

/// The take's control on every page: its time and Stop once audio arrives, Cancel while it is still starting.
struct RecordingToolbarButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let startedAt = model.recordingStartedAt {
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                let elapsed = context.date.timeIntervalSince(startedAt)
                Button {
                    model.stopRecordingAndTranscribe()
                } label: {
                    HStack(spacing: DS.Spacing.snug) {
                        Circle()
                            .fill(.foreground)
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                        Text(verbatim: AppFormat.elapsed(elapsed))
                            .monospacedDigit()
                        Text("Stop")
                    }
                    .font(DS.Font.bodyStrong)
                }
                .buttonStyle(.glassProminent)
                .tint(DS.Color.recordingFill)
                .help("Stop recording and transcribe.")
                .accessibilityLabel("Stop Recording")
                .accessibilityValue(AppFormat.duration(seconds: elapsed))
                .accessibilityAddTraits(.updatesFrequently)
                .accessibilityIdentifier("toolbar.stopRecording")
                .axLeaf("Toolbar.Button.StopRecording")
            }
        } else {
            Button("Cancel") { model.cancelRecordingBeforeCapture() }
                .font(DS.Font.bodyStrong)
                .buttonStyle(.glass)
                .help("Cancel the recording before it starts.")
                .accessibilityIdentifier("toolbar.stopRecording")
                .axLeaf("Toolbar.Button.StopRecording")
        }
    }
}
