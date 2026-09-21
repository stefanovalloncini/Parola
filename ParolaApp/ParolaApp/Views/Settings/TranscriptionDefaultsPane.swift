import SwiftUI
import ParolaCore

struct TranscriptionDefaultsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 12) {
            SettingsSection {
                SettingRow("Default model",
                           description: "Applies to every new transcription and to dictation. The toolbar model picker edits this same setting.",
                           isFirst: true) {
                    ModelPickerView(shell: .standalone, leaf: "TranscriptionDefaults.Picker.Model")
                }
                SettingRow("Default language",
                           description: "Auto detects the language from the audio with Whisper models. Pick one when the audio language is known.") {
                    LanguagePickerView(shell: .standalone, leaf: "TranscriptionDefaults.Picker.Language")
                        .disabled(model.selectedModelCapabilities.supportedLanguages.isEnglishOnly)
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
        }
    }
}

