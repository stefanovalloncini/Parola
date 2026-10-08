import SwiftUI
import ParolaCore

struct TranscriptionDefaultsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        return SettingsForm {
            Section {
                SettingRow("Default model",
                           description: "Applies to every new transcription and to dictation. The model picker on the Library page edits this same setting.") {
                    ModelPickerView(leaf: "TranscriptionDefaults.Picker.Model")
                }
                SettingRow("Default language",
                           description: "Auto detects the language from the audio with Whisper models. Pick one when the audio language is known.") {
                    DefaultLanguagePicker(leaf: "TranscriptionDefaults.Picker.Language")
                        .disabled(model.selectedModelCapabilities.supportedLanguages.isEnglishOnly)
                }
                SettingRow("Word timestamps",
                           description: "Records when each word starts and ends, so the word highlight and a click on a word land exactly. Transcribing takes longer.") {
                    Toggle("", isOn: $model.wordTimestamps).labelsHidden()
                        .axLeaf("TranscriptionDefaults.Toggle.WordTimestamps")
                }
                SettingRow("Detect speakers",
                           description: "Splits the transcript by speaker, so each one can be named. Slower, and loads a second model the first time.") {
                    Toggle("", isOn: $model.diarize).labelsHidden()
                        .axLeaf("TranscriptionDefaults.Toggle.Diarize")
                }
            } footer: {
                VStack(alignment: .leading, spacing: DS.Spacing.hair) {
                    if let warning = model.languageMismatchWarning {
                        SettingsWarning(warning)
                            .axLeaf("TranscriptionDefaults.Label.LanguageWarning")
                    }
                    if let notice = model.englishOnlyAutoNotice {
                        SettingsWarning(notice)
                            .axLeaf("TranscriptionDefaults.Label.EnglishOnlyAutoNotice")
                    }
                    if let warning = model.diarizeMismatchWarning {
                        SettingsWarning(warning)
                            .axLeaf("TranscriptionDefaults.Label.DiarizeWarning")
                    }
                    Text("The Library page shows these same settings; a change in either place persists.")
                        .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
            }

            SettingsSection("Custom vocabulary") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Custom vocabulary", text: $model.initialPrompt,
                              prompt: Text("Names or jargon, comma-separated"), axis: .vertical)
                        .labelsHidden()
                        .lineLimit(2...6)
                        .textFieldStyle(.roundedBorder)
                        .axLeaf("TranscriptionDefaults.TextField.InitialPrompt")
                    Text("A short list of names or jargon helps Whisper get unusual words right. Other engines ignore it.")
                        .font(DS.Font.secondary)
                        .foregroundStyle(DS.Color.secondaryText)
                }
            }

            SettingsSection("Playback") {
                SettingRow("Pause when app is hidden",
                           description: "Pauses the player when you switch to another app.") {
                    Toggle("", isOn: $model.pausePlayerOnAppHidden).labelsHidden()
                        .axLeaf("Playback.Toggle.PauseOnHidden")
                }
            }

            ResetPaneButton(scope: .transcriptionDefaults)
        }
    }
}

