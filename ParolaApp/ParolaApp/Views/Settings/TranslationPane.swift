import SwiftUI
import ParolaCore

struct TranslationPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 12) {
            SettingsSection {
                SettingRow("Translation provider",
                           description: "Translating a finished transcript runs on your Mac.",
                           isFirst: true) {
                    Text("Apple Translation (on device)")
                        .font(DS.Font.secondary)
                        .foregroundStyle(DS.Color.secondaryText)
                        .axLeaf("Translation.Label.Provider")
                }
                SettingRow("Show translations side by side",
                           description: "Off puts the translation under each segment instead of beside it.") {
                    Toggle("", isOn: $model.translationSideBySide).labelsHidden()
                        .axLeaf("Translation.Toggle.SideBySide")
                }
            }
            SettingsSection {
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
