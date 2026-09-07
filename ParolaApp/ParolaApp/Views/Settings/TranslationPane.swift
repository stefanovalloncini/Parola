import SwiftUI
import ParolaCore

struct TranslationPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 12) {
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
                    .font(DS.Font.callout)
                    .foregroundStyle(DS.Color.warningText)
                    .axLeaf("Translation.Label.TranslateWarning")
            }
            SettingHelper(text: "Whisper translates from the detected source language into English. Only multilingual Whisper models can translate.")
            ResetPaneButton(scope: .translation)
        }
    }
}
