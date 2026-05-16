import SwiftUI
import ParolaCore

struct TranslationPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSection {
                SettingRow("Translate to English by default",
                           description: "Apply translation to every new transcription unless overridden.",
                           isFirst: true) {
                    Toggle("", isOn: $model.translate).labelsHidden()
                }
            }
            SettingHelper(text: "Whisper translates from the detected source language into English.")
        }
    }
}
