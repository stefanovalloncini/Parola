import SwiftUI
import ParolaCore

struct TranslationPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        return SettingsForm {
            SettingsSection("After transcribing") {
                SettingRow("Show translations side by side",
                           description: "Off puts the translation under each segment instead of beside it.") {
                    Toggle("", isOn: $model.translationSideBySide).labelsHidden()
                        .axLeaf("Translation.Toggle.SideBySide")
                }
            }
            SettingHelper(text: "A finished transcript is translated with Apple Translation, on your Mac, into any language it offers.")
            Section {
                SettingRow("Translate to English by default",
                           description: "Applies to new file, mic, batch, and YouTube transcriptions. Live captions has its own toggle; dictation always keeps the spoken language.") {
                    Toggle("", isOn: $model.translate).labelsHidden()
                        .axLeaf("Translation.Toggle.TranslateByDefault")
                }
            } header: {
                Text("While transcribing")
            } footer: {
                VStack(alignment: .leading, spacing: DS.Spacing.hair) {
                    if let warning = model.translateMismatchWarning {
                        SettingsWarning(warning)
                            .axLeaf("Translation.Label.TranslateWarning")
                    }
                    Text("Whisper translates from the detected source language into English. Only multilingual Whisper models can translate.")
                        .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            ResetPaneButton(scope: .translation)
        }
    }
}
