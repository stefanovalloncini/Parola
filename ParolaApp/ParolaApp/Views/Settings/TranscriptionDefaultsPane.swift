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
                    Picker("", selection: Binding(
                        get: { model.selectedModel },
                        set: { model.activateModel($0) }
                    )) {
                        ForEach(model.availableModels, id: \.name) { info in
                            Text(info.label).tag(info.name)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(minWidth: 220, alignment: .trailing)
                    .axLeaf("TranscriptionDefaults.Picker.Model")
                }
                SettingRow("Default language",
                           description: "Auto detects the language from the audio with Whisper models. Pick one when the audio language is known.") {
                    Picker("", selection: languageBinding) {
                        Text("Auto").tag(String?.none)
                        ForEach(SupportedLanguages.options, id: \.code) { option in
                            Text(option.name).tag(String?.some(option.code))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(minWidth: 220, alignment: .trailing)
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
                    .font(DS.Font.callout)
                    .foregroundStyle(DS.Color.warningText)
                    .padding(.top, 2)
                    .axLeaf("TranscriptionDefaults.Label.LanguageWarning")
            }
            if let notice = model.englishOnlyAutoNotice {
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .font(DS.Font.callout)
                    .foregroundStyle(DS.Color.warningText)
                    .padding(.top, 2)
                    .axLeaf("TranscriptionDefaults.Label.EnglishOnlyAutoNotice")
            }
            if let warning = model.diarizeMismatchWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(DS.Font.callout)
                    .foregroundStyle(DS.Color.warningText)
                    .padding(.top, 2)
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

    private var languageBinding: Binding<String?> {
        Binding(
            get: { model.selectedLanguage },
            set: { model.selectedLanguage = $0 }
        )
    }
}

