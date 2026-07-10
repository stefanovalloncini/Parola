import SwiftUI
import ParolaCore

struct TranscriptionDefaultsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 12) {
            SettingsSection {
                SettingRow("Default model",
                           description: "Applies to every new transcription. The toolbar model picker edits this same setting.",
                           isFirst: true) {
                    Picker("", selection: $model.selectedModel) {
                        ForEach(model.availableModels, id: \.name) { info in
                            Text(info.label).tag(info.name)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(minWidth: 220)
                    .axLeaf("TranscriptionDefaults.Picker.Model")
                }
                SettingRow("Default language",
                           description: "Auto detects the language from the audio with Whisper models. Pick one when the audio language is known.") {
                    Picker("", selection: languageBinding) {
                        Text("Auto").tag(String?.none)
                        ForEach(LanguageOptions.options, id: \.code) { option in
                            Text(option.name).tag(String?.some(option.code))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(minWidth: 220)
                    .axLeaf("TranscriptionDefaults.Picker.Language")
                }
                SettingRow("Word timestamps",
                           description: "Captures the start and end time of each word. Karaoke estimates timings without it.") {
                    Toggle("", isOn: $model.wordTimestamps).labelsHidden()
                        .axLeaf("TranscriptionDefaults.Toggle.WordTimestamps")
                }
                SettingRow("Diarize speakers",
                           description: "Identify multiple speakers in the audio (slower).") {
                    Toggle("", isOn: $model.diarize).labelsHidden()
                        .axLeaf("TranscriptionDefaults.Toggle.Diarize")
                }
            }
            if let warning = model.languageMismatchWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(.top, 2)
                    .axLeaf("TranscriptionDefaults.Label.LanguageWarning")
            }
            SettingHelper(text: "The main-window toolbar shows these same settings; a change in either place persists.")

            SettingsSection("Playback") {
                SettingRow("Pause when app is hidden",
                           description: "Pauses the player when you switch to another app.",
                           isFirst: true) {
                    Toggle("", isOn: $model.pausePlayerOnAppHidden).labelsHidden()
                        .axLeaf("Playback.Toggle.PauseOnHidden")
                }
            }

            SettingsSection("Privacy") {
                SettingRow("Privacy mode",
                           description: "Disable all cloud LLM calls. Local models stay available.",
                           isFirst: true) {
                    Toggle("", isOn: $model.userPrivacyMode).labelsHidden()
                        .axLeaf("Privacy.Toggle.PrivacyMode")
                }
            }

            ResetPaneButton(scope: .transcriptionDefaults)
            ResetAllSettingsButton()
        }
    }

    private var languageBinding: Binding<String?> {
        Binding(
            get: { model.selectedLanguage },
            set: { model.selectedLanguage = $0 }
        )
    }
}

private enum LanguageOptions {
    static let options: [(code: String, name: String)] = [
        ("en", "English"),
        ("it", "Italian"),
        ("fr", "French"),
        ("de", "German"),
        ("es", "Spanish"),
        ("pt", "Portuguese"),
        ("nl", "Dutch"),
        ("ja", "Japanese"),
        ("zh", "Chinese"),
        ("ko", "Korean"),
        ("ru", "Russian"),
        ("ar", "Arabic"),
        ("hi", "Hindi")
    ]
}
