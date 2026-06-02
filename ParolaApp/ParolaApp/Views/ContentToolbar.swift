import SwiftUI
import ParolaCore

struct ContentToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        @Bindable var model = model
        ToolbarItem(placement: .navigation) {
            HStack(spacing: DS.Spacing.small) {
                ModelPickerView()
                LanguagePickerView()
                    .disabled(selectedModelIsEnglishOnly)
                    .modifier(EnglishOnlyHelpModifier(isEnglishOnly: selectedModelIsEnglishOnly))
            }
        }
        ToolbarItemGroup(placement: .navigation) {
            if selectedModelSupportsTranslate {
                Toggle(isOn: $model.translate) {
                    HStack(spacing: 4) {
                        Image(systemName: "character.bubble")
                        Text("Translate")
                    }
                }
                .toggleStyle(.button)
                .help("Translate to English instead of transcribing in the source language.")
                .accessibilityIdentifier("toolbar.translate")
                .axLeaf("Toolbar.Toggle.Translate")
            }
            Toggle(isOn: $model.diarize) {
                HStack(spacing: 4) {
                    Image(systemName: "person.2.wave.2")
                    Text("Diarize")
                }
            }
            .toggleStyle(.button)
            .help("Identify multiple speakers in the audio (slower).")
            .accessibilityIdentifier("toolbar.diarize")
            .axLeaf("Toolbar.Toggle.Diarize")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if model.route != .batch {
                Button {
                    model.route = .batch
                } label: {
                    Label("Batch", systemImage: "square.stack.3d.up")
                }
                .help("Open the batch transcription page.")
                .accessibilityIdentifier("toolbar.batch")
                .axLeaf("Toolbar.Button.Batch")
            }
            if !model.deletedEntries.isEmpty {
                Button { model.showingTrash = true } label: {
                    Label("Recently Deleted", systemImage: "trash")
                }
                .help("Show Recently Deleted")
                .accessibilityIdentifier("toolbar.recentlyDeleted")
                .axLeaf("Toolbar.Button.RecentlyDeleted")
            }
            Button {
                model.youtubeSheetOpen = true
            } label: {
                Label("YouTube URL", systemImage: "play.rectangle.on.rectangle")
            }
            .disabled(isBusy)
            .help("Transcribe from a YouTube URL.")
            .accessibilityIdentifier("toolbar.youtube")
            .axLeaf("Toolbar.Button.YouTube")

            if isRecording {
                Button {
                    model.stopRecordingAndTranscribe()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .tint(.red)
                .help("Stop recording and transcribe.")
                .accessibilityIdentifier("toolbar.stopRecording")
                .axLeaf("Toolbar.Button.StopRecording")
            } else {
                Menu {
                    Button("Microphone") { model.startRecording(source: .microphone) }
                        .accessibilityIdentifier("toolbar.record.microphone")
                        .axLeaf("Toolbar.MenuItem.RecordMicrophone")
                    Button("System audio") { model.startRecording(source: .systemAudio) }
                        .accessibilityIdentifier("toolbar.record.system")
                        .axLeaf("Toolbar.MenuItem.RecordSystem")
                } label: {
                    Label("Record", systemImage: "mic.fill")
                }
                .disabled(isBusy)
                .help("Record from the microphone or system audio.")
                .accessibilityIdentifier("toolbar.record")
                .axLeaf("Toolbar.Menu.Record")
            }

            PromptsMenu()
                .disabled(model.transcript == nil || model.isRunningPrompt)

            Button {
                model.presentOpenPanel()
            } label: {
                Label("Open File", systemImage: "doc.badge.plus")
            }
            .disabled(isBusy)
            .help("Open an audio or video file.")
            .accessibilityIdentifier("toolbar.openFile")
            .axLeaf("Toolbar.Button.OpenFile")
        }
    }

    private var selectedModelIsEnglishOnly: Bool {
        model.selectedModelCapabilities.supportedLanguages.isEnglishOnly
    }
    private var selectedModelSupportsTranslate: Bool {
        model.selectedModelCapabilities.supportsTranslate
    }

    private var isBusy: Bool {
        switch model.phase {
        case .idle, .ready, .failed: return false
        default: return true
        }
    }

    private var isRecording: Bool {
        if case .recording = model.phase { return true }
        return false
    }
}

private struct EnglishOnlyHelpModifier: ViewModifier {
    let isEnglishOnly: Bool
    func body(content: Content) -> some View {
        content.help(isEnglishOnly ? "This model is English-only." : "")
    }
}
