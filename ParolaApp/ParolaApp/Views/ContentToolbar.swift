import SwiftUI
import ParolaCore

struct ContentToolbar: ToolbarContent {
    @EnvironmentObject var model: AppModel
    @Binding var showingTrash: Bool

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            ModelPickerView()
            LanguagePickerView()
                .disabled(selectedModelIsEnglishOnly)
                .help(selectedModelIsEnglishOnly ? "This model is English-only." : "")
            if selectedModelSupportsTranslate {
                Toggle(isOn: $model.translate) {
                    HStack(spacing: 4) {
                        Image(systemName: "character.bubble")
                        Text("Translate")
                    }
                }
                .toggleStyle(.button)
                .help("Translate to English instead of transcribing in the source language.")
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if model.route != .batch {
                Button {
                    model.route = .batch
                } label: {
                    Label("Batch", systemImage: "square.stack.3d.up")
                }
                .help("Open the batch transcription page.")
            }
            if !model.deletedEntries.isEmpty {
                Button { showingTrash = true } label: {
                    Label("Recently Deleted", systemImage: "trash")
                }
                .help("Show Recently Deleted")
            }
            Button {
                model.youtubeSheetOpen = true
            } label: {
                Label("YouTube URL", systemImage: "play.rectangle.on.rectangle")
            }
            .disabled(isBusy)
            .help("Transcribe from a YouTube URL.")

            Menu {
                Button("Microphone") { model.startRecording(source: .microphone) }
                Button("System audio") { model.startRecording(source: .systemAudio) }
            } label: {
                Label("Record", systemImage: "mic.fill")
            }
            .disabled(isBusy)
            .help("Record from the microphone or system audio.")

            PromptsMenu()
                .disabled(model.transcript == nil || model.isRunningPrompt)

            Button {
                model.presentOpenPanel()
            } label: {
                Label("Open File", systemImage: "doc.badge.plus")
            }
            .disabled(isBusy)
            .help("Open an audio or video file.")
        }
    }

    private var selectedModelCapabilities: EngineCapabilities {
        ModelCatalog.staticCapabilities(forID: model.selectedModel) ?? .whisperKitDefaults
    }
    private var selectedModelIsEnglishOnly: Bool {
        selectedModelCapabilities.supportedLanguages.isEnglishOnly
    }
    private var selectedModelSupportsTranslate: Bool {
        selectedModelCapabilities.supportsTranslate
    }

    private var isBusy: Bool {
        switch model.phase {
        case .idle, .ready, .failed: return false
        default: return true
        }
    }
}
