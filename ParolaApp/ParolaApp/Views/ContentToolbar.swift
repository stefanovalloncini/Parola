import SwiftUI
import ParolaCore

struct ContentToolbar: ToolbarContent {
    @EnvironmentObject var model: AppModel

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            ModelPickerView()
            LanguagePickerView()
                .disabled(selectedModelIsEnglishOnly)
                .modifier(EnglishOnlyHelpModifier(isEnglishOnly: selectedModelIsEnglishOnly))
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
            }
            if !model.deletedEntries.isEmpty {
                Button { model.showingTrash = true } label: {
                    Label("Recently Deleted", systemImage: "trash")
                }
                .help("Show Recently Deleted")
                .accessibilityIdentifier("toolbar.recentlyDeleted")
            }
            Button {
                model.youtubeSheetOpen = true
            } label: {
                Label("YouTube URL", systemImage: "play.rectangle.on.rectangle")
            }
            .disabled(isBusy)
            .help("Transcribe from a YouTube URL.")
            .accessibilityIdentifier("toolbar.youtube")

            Menu {
                Button("Microphone") { model.startRecording(source: .microphone) }
                    .accessibilityIdentifier("toolbar.record.microphone")
                Button("System audio") { model.startRecording(source: .systemAudio) }
                    .accessibilityIdentifier("toolbar.record.system")
            } label: {
                Label("Record", systemImage: "mic.fill")
            }
            .disabled(isBusy)
            .help("Record from the microphone or system audio.")
            .accessibilityIdentifier("toolbar.record")

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
}

private struct EnglishOnlyHelpModifier: ViewModifier {
    let isEnglishOnly: Bool
    func body(content: Content) -> some View {
        if isEnglishOnly {
            content.help("This model is English-only.")
        } else {
            content
        }
    }
}
