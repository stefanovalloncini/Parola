import SwiftUI
import ParolaCore

struct TranscriptionDefaultsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 12) {
            SettingsSection {
                SettingRow("Default model",
                           description: "Applies to every new transcription and to dictation. The model picker on the Library page edits this same setting.",
                           isFirst: true) {
                    ModelPickerView(leaf: "TranscriptionDefaults.Picker.Model")
                }
                SettingRow("Default language",
                           description: "Auto detects the language from the audio with Whisper models. Pick one when the audio language is known.") {
                    LanguagePickerView(leaf: "TranscriptionDefaults.Picker.Language")
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
            }
            if let warning = model.languageMismatchWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Color.warningText)
                    .padding(.top, DS.Spacing.hair)
                    .axLeaf("TranscriptionDefaults.Label.LanguageWarning")
            }
            if let notice = model.englishOnlyAutoNotice {
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Color.warningText)
                    .padding(.top, DS.Spacing.hair)
                    .axLeaf("TranscriptionDefaults.Label.EnglishOnlyAutoNotice")
            }
            if let warning = model.diarizeMismatchWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Color.warningText)
                    .padding(.top, DS.Spacing.hair)
                    .axLeaf("TranscriptionDefaults.Label.DiarizeWarning")
            }
            SettingHelper(text: "The Library page shows these same settings; a change in either place persists.")

            SettingsSection("Custom vocabulary") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Custom vocabulary", text: $model.initialPrompt,
                              prompt: Text("Names or jargon, comma-separated"), axis: .vertical)
                        .labelsHidden()
                        .lineLimit(2...6)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Custom vocabulary")
                        .axLeaf("TranscriptionDefaults.TextField.InitialPrompt")
                    Text("A short list of names or jargon helps Whisper get unusual words right. Other engines ignore it.")
                        .font(DS.Font.secondary)
                        .foregroundStyle(DS.Color.secondaryText)
                }
                .padding(DS.Spacing.medium)
            }

            SettingsSection("Playback") {
                SettingRow("Pause when app is hidden",
                           description: "Pauses the player when you switch to another app.",
                           isFirst: true) {
                    Toggle("", isOn: $model.pausePlayerOnAppHidden).labelsHidden()
                        .axLeaf("Playback.Toggle.PauseOnHidden")
                }
            }

            ResetPaneButton(scope: .transcriptionDefaults)
        }
    }
}

