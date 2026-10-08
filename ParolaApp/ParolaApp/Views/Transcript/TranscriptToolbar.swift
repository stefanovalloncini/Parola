import SwiftUI
import ParolaCore

/// Back at the leading edge, then the pane switch, as Finder puts its view switch after Back and Forward.
struct TranscriptLeadingItems: ToolbarContent {
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            TranscriptBackLink()
        }
        if model.features.isEnabled(.ai) {
            ToolbarItem {
                TranscriptPanePicker()
            }
        }
    }
}

/// The document's own controls, one glass group before Record.
struct TranscriptActionItems: ToolbarContent {
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            TranscriptFormatMenu()
            ReadAloudToolbarButton()
            if model.features.isEnabled(.ai) {
                AskAIMenu()
            }
            TranscriptShareMenu()
        }
    }
}

struct TranscriptPanePicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Picker("View", selection: paneModeBinding) {
            ForEach(AppModel.TranscriptPaneMode.allCases.filter { model.canShow($0) }, id: \.self) { mode in
                Text(Self.label(mode)).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Switch between Transcript, Summary and Chat")
        .axLeaf("Toolbar.Transcript.Picker.PaneMode")
    }

    private var paneModeBinding: Binding<AppModel.TranscriptPaneMode> {
        Binding(
            get: { model.transcriptPaneMode },
            set: { model.setTranscriptPaneMode($0) }
        )
    }

    static func label(_ mode: AppModel.TranscriptPaneMode) -> String {
        switch mode {
        case .transcript: return String(localized: "Transcript")
        case .summary: return String(localized: "Summary")
        case .chat: return String(localized: "Chat")
        }
    }
}

/// Aa: how the transcript reads. Only the Transcript pane has text to lay out.
struct TranscriptFormatMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            TranscriptFormatItems()
        } label: {
            Label("Format", systemImage: "textformat")
        }
        .menuIndicator(.hidden)
        .disabled(model.transcriptPaneMode != .transcript)
        .help("Layout and display options")
        .axLeaf("Toolbar.Transcript.Menu.Format")
    }
}

/// The View menu's layout and display items, in its order and with its rules.
struct TranscriptFormatItems: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Picker("Layout", selection: layoutBinding) {
            Text("Paragraphs").tag(TranscriptDisplayMode.transcript)
            Text("Segments").tag(TranscriptDisplayMode.segments)
        }
        .pickerStyle(.inline)
        .axLeaf("Toolbar.Transcript.Picker.Layout")
        Divider()
        Toggle("Show Translations Side by Side", isOn: $model.translationSideBySide)
            .disabled(!model.hasTranslation)
            .axLeaf("Toolbar.Transcript.MenuItem.TranslationSideBySide")
        Toggle("Compact Text", isOn: $model.transcriptCompact)
            .disabled(!model.compactTextApplies)
            .axLeaf("Toolbar.Transcript.MenuItem.CompactText")
        Toggle("Show Favorites Only", isOn: $model.favoritesOnly)
            .disabled(!model.favoritesOnly && !model.selectedEntryHasFavorites)
            .axLeaf("Toolbar.Transcript.MenuItem.FavoritesOnly")
        Toggle("Subtitle Warnings", isOn: $model.showSubtitleQC)
            .disabled(model.transcriptDisplayMode != .segments)
            .axLeaf("Toolbar.Transcript.MenuItem.SubtitleWarnings")
    }

    private var layoutBinding: Binding<TranscriptDisplayMode> {
        Binding(
            get: { model.transcriptDisplayMode },
            set: { model.showTranscriptLayout($0) }
        )
    }
}

/// Reads the whole transcript out; a source-aware Read Aloud button replaces this view as a unit.
struct ReadAloudToolbarButton: View {
    @Environment(AppModel.self) private var model
    @State private var speaker = TranscriptSpeaker()

    var body: some View {
        Button(action: toggle) {
            Label(title, systemImage: speaker.isSpeaking ? "speaker.wave.2.fill" : "speaker.wave.2")
        }
        .disabled(model.transcript == nil)
        .help(help)
        .axLeaf("Toolbar.Transcript.Button.ReadAloud")
    }

    private var title: LocalizedStringKey { speaker.isSpeaking ? "Stop Reading" : "Read Aloud" }
    private var help: LocalizedStringKey { speaker.isSpeaking ? "Stop reading" : "Read aloud" }

    private func toggle() {
        if speaker.isSpeaking {
            speaker.stop()
        } else if model.transcript != nil {
            speaker.speak(model.transcriptText, languageCode: model.transcript?.language)
        }
    }
}

struct TranscriptShareMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            TranscriptShareItems()
        } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        .menuIndicator(.hidden)
        .disabled(model.transcript == nil)
        .help("Export and share")
        .axLeaf("Toolbar.Transcript.Menu.Share")
    }
}

/// Share's items: export first, then the copies, then the ways to send it on.
struct TranscriptShareItems: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button("Export…") { model.openExportSheet() }
            .axLeaf("Toolbar.Transcript.MenuItem.Export")
        Menu("Export As") {
            ForEach(model.exportPresets) { preset in
                Button { model.exportWithPreset(preset.id) } label: {
                    ExportPresetChecks.label(preset)
                }
            }
        }
        Divider()
        Button("Copy Transcript") { Task { await model.copyTranscript() } }
            .axLeaf("Toolbar.Transcript.MenuItem.CopyTranscript")
        Button("Copy with Timestamps") {
            model.copyTranscriptToPasteboard(withTimestamps: true, pasteboard: .general)
        }
        Divider()
        Button("Share…") { model.shareTranscriptAsTextFile() }
        Button("Send via Mail…") { model.shareTranscriptViaMail() }
        Button("Print Transcript…") { model.printTranscript() }
    }
}

/// The toolbar's twin of View ▸ Show Inspector, so a hidden inspector always has a way back.
struct InspectorToolbarToggle: View {
    @Environment(AppModel.self) private var model
    @AppStorage(InspectorVisibility.preferenceKey, store: DefaultsStore.current) private var preference = true
    @AppStorage(InspectorVisibility.forcedAtNarrowWidthKey, store: DefaultsStore.current)
    private var forcedAtNarrowWidth = false

    var body: some View {
        let title = InspectorVisibility.commandTitle(
            showing: InspectorVisibility.isVisible(
                preference: preference, forcedAtNarrowWidth: forcedAtNarrowWidth, isNarrow: model.transcriptPaneIsNarrow
            )
        )
        Button {
            InspectorVisibility.toggle(in: DefaultsStore.current, isNarrow: model.transcriptPaneIsNarrow)
        } label: {
            Label(title, systemImage: "sidebar.trailing")
        }
        .help(title)
        .axLeaf("Toolbar.Transcript.Button.Inspector")
    }
}
