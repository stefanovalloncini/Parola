import SwiftUI
import ParolaCore

struct GeneralPane: View {
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin: Bool = LaunchAtLogin.isEnabled
    @State private var launchAtLoginError: String?

    var body: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 16) {
            SettingsSection("Startup") {
                SettingRow("Open at login",
                           descriptionVerbatim: launchAtLoginError ?? String(localized: "Launches Parola in the background when you sign in."),
                           isFirst: true) {
                    Toggle("", isOn: $launchAtLogin)
                        .labelsHidden()
                        .onChange(of: launchAtLogin) { _, newValue in
                            do {
                                try LaunchAtLogin.setEnabled(newValue)
                                launchAtLoginError = nil
                            } catch {
                                launchAtLogin = LaunchAtLogin.isEnabled
                                launchAtLoginError = error.localizedDescription
                            }
                        }
                        .axLeaf("General.Toggle.LaunchAtLogin")
                }
                SettingRow("Show menu bar icon",
                           description: "Adds a Parola item to the system menu bar with quick actions and recent transcripts.") {
                    Toggle("", isOn: $model.showMenuBarExtra).labelsHidden()
                        .axLeaf("General.Toggle.MenuBarExtra")
                }
            }

            SettingsSection {
                SettingRow("Highlight the word being spoken",
                           description: "Bolds and tints the current word as audio plays.",
                           isFirst: true) {
                    Toggle("", isOn: $model.karaokeHighlight)
                        .labelsHidden()
                        .onChange(of: model.karaokeHighlight) { _, isOn in
                            if !isOn { model.wordTimestamps = false }
                        }
                        .axLeaf("General.Toggle.KaraokeHighlight")
                }
                SettingRow("Use precise word timings",
                           description: "Asks Whisper for word-level timestamps. More accurate karaoke, but slower.") {
                    Toggle("", isOn: $model.wordTimestamps)
                        .labelsHidden()
                        .disabled(!model.karaokeHighlight)
                        .axLeaf("General.Toggle.WordTimestamps")
                }
                SettingRow("Stream microphone in real time",
                           description: "Transcript appears as you speak. Off records the whole take first, then transcribes.") {
                    Toggle("", isOn: $model.useStreaming).labelsHidden()
                        .axLeaf("General.Toggle.UseStreaming")
                }
                SettingRow("Identify speakers",
                           description: "Tags each segment with Speaker 1, Speaker 2, etc. Loads a second model on first use.") {
                    Toggle("", isOn: $model.diarize).labelsHidden()
                        .axLeaf("General.Toggle.Diarize")
                }
            }

            SettingsSection("Custom vocabulary") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Names or jargon, comma-separated",
                              text: $model.initialPrompt, axis: .vertical)
                        .lineLimit(2...6)
                        .textFieldStyle(.roundedBorder)
                        .axLeaf("General.TextField.InitialPrompt")
                    Text("A short list of names or jargon helps Whisper get unusual words right.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
            }
            ResetPaneButton(scope: .general)
        }
    }
}
