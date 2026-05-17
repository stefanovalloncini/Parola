import SwiftUI
import ParolaCore

struct GeneralPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSection {
                SettingRow("Highlight the word being spoken",
                           description: "Bolds and tints the current word as audio plays.",
                           isFirst: true) {
                    Toggle("", isOn: $model.karaokeHighlight)
                        .labelsHidden()
                        .onChange(of: model.karaokeHighlight) { _, isOn in
                            if !isOn { model.wordTimestamps = false }
                        }
                }
                SettingRow("Use precise word timings",
                           description: "Asks Whisper for word-level timestamps. More accurate karaoke, but slower.") {
                    Toggle("", isOn: $model.wordTimestamps)
                        .labelsHidden()
                        .disabled(!model.karaokeHighlight)
                }
                SettingRow("Stream microphone in real time",
                           description: "Transcript appears as you speak. Off records the whole take first, then transcribes.") {
                    Toggle("", isOn: $model.useStreaming).labelsHidden()
                }
                SettingRow("Identify speakers",
                           description: "Tags each segment with Speaker 1, Speaker 2, etc. Loads a second model on first use.") {
                    Toggle("", isOn: $model.diarize).labelsHidden()
                }
            }

            SettingsSection("Custom vocabulary") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Names or jargon, comma-separated",
                              text: $model.initialPrompt, axis: .vertical)
                        .lineLimit(2...6)
                        .textFieldStyle(.roundedBorder)
                    Text("A short list of names or jargon helps Whisper get unusual words right.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(16)
            }
            ResetPaneButton(scope: .general)
        }
    }
}
