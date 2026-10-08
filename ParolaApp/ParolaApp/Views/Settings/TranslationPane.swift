import SwiftUI
import ParolaCore

struct TranslationPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        return SettingsForm {
            SettingsSection("After transcribing") {
                SettingRow("Show translations side by side",
                           description: "Off puts the translation under each segment instead of beside it.",
                           isFirst: true) {
                    Toggle("", isOn: $model.translationSideBySide).labelsHidden()
                        .axLeaf("Translation.Toggle.SideBySide")
                }
            }
            SettingHelper(text: "A finished transcript is translated with Apple Translation, on your Mac, into any language it offers.")
            SettingsSection("While transcribing") {
                SettingRow("Translate to English by default",
                           description: "Applies to new file, mic, batch, and YouTube transcriptions. Live captions has its own toggle; dictation always keeps the spoken language.",
                           isFirst: true) {
                    Toggle("", isOn: $model.translate).labelsHidden()
                        .axLeaf("Translation.Toggle.TranslateByDefault")
                }
            }
            if let warning = model.translateMismatchWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Color.warningText)
                    .axLeaf("Translation.Label.TranslateWarning")
            }
            SettingHelper(text: "Whisper translates from the detected source language into English. Only multilingual Whisper models can translate.")
            ResetPaneButton(scope: .translation)
        }
    }
}
