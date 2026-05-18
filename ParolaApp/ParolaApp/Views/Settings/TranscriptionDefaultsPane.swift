import SwiftUI
import ParolaCore

struct TranscriptionDefaultsPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSection {
                SettingRow("Default model",
                           description: "Used when you start a transcription without picking one in the toolbar.",
                           isFirst: true) {
                    Picker("", selection: $model.selectedModel) {
                        ForEach(model.availableModels, id: \.name) { info in
                            Text(info.label).tag(info.name)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(minWidth: 220)
                }
                SettingRow("Default language",
                           description: "Auto picks the language from the audio. Override when the audio is in a known language.") {
                    Picker("", selection: languageBinding) {
                        Text("Auto").tag(String?.none)
                        ForEach(LanguageOptions.options, id: \.code) { option in
                            Text(option.name).tag(String?.some(option.code))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(minWidth: 220)
                }
                SettingRow("Word timestamps",
                           description: "Captures the start and end time of each word. Required for karaoke highlight.") {
                    Toggle("", isOn: $model.wordTimestamps).labelsHidden()
                }
                SettingRow("Diarize speakers",
                           description: "Identify multiple speakers in the audio (slower).") {
                    Toggle("", isOn: $model.diarize).labelsHidden()
                }
            }
            SettingHelper(text: "The main-window toolbar overrides these per transcript.")

            SettingsSection("Playback") {
                SettingRow("Pause when app is hidden",
                           description: "Pauses the player when you switch to another app.",
                           isFirst: true) {
                    Toggle("", isOn: $model.pausePlayerOnAppHidden).labelsHidden()
                }
            }

            SettingsSection("Privacy") {
                SettingRow("Privacy mode",
                           description: "Disable all cloud LLM calls. Local models stay available.",
                           isFirst: true) {
                    Toggle("", isOn: $model.userPrivacyMode).labelsHidden()
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
