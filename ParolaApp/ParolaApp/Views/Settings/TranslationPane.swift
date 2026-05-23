import SwiftUI
import ParolaCore

struct TranslationPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 12) {
            SettingsSection {
                SettingRow("Translate to English by default",
                           description: "Apply translation to every new transcription unless overridden.",
                           isFirst: true) {
                    Toggle("", isOn: $model.translate).labelsHidden()
                }
            }
            SettingHelper(text: "Whisper translates from the detected source language into English.")
            ResetPaneButton(scope: .translation)
        }
    }
}
