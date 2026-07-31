import SwiftUI
import ParolaCore

struct GeneralPane: View {
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin: Bool = LaunchAtLogin.isEnabled
    @State private var launchAtLoginError: String?

    static func showsStreamMicrophoneRow(features: FeatureSet) -> Bool {
        features.isEnabled(.micRecording) || features.isEnabled(.dictation) || features.isEnabled(.liveCaptions)
    }

    var body: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 16) {
            SettingsSection("Startup") {
                SettingRow("Open at login",
                           descriptionVerbatim: launchAtLoginError ?? String(localized: "Opens Parola automatically when you sign in."),
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
                        // SMAppService can change in System Settings while this pane is open;
                        // re-read on appearance.
                        .onAppear { launchAtLogin = LaunchAtLogin.isEnabled }
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
                        .axLeaf("General.Toggle.KaraokeHighlight")
                }
                SettingRow("Word timestamps",
                           description: "Captures the start and end time of each word. More accurate karaoke and word click-to-seek, but slower.") {
                    Toggle("", isOn: $model.wordTimestamps)
                        .labelsHidden()
                        .axLeaf("General.Toggle.WordTimestamps")
                }
                if Self.showsStreamMicrophoneRow(features: model.features) {
                    SettingRow("Stream microphone in real time",
                               description: "Transcript appears as you speak — Whisper models only; other engines record the take first. Off always records first, then transcribes.") {
                        Toggle("", isOn: $model.useStreaming).labelsHidden()
                            .axLeaf("General.Toggle.UseStreaming")
                    }
                }
                SettingRow("Diarize speakers",
                           description: "Tags each segment with Speaker 1, Speaker 2, etc. Loads a second model on first use.") {
                    Toggle("", isOn: $model.diarize).labelsHidden()
                        .axLeaf("General.Toggle.Diarize")
                }
                if let warning = model.diarizeMismatchWarning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(DS.Font.callout)
                        .foregroundStyle(DS.Palette.warning)
                        .padding(.top, 2)
                        .axLeaf("General.Label.DiarizeWarning")
                }
                SettingRow("Name transcripts automatically",
                           description: "Generates a short title from the content on device when a transcription finishes. Batch files keep their file names.") {
                    Toggle("", isOn: $model.autoTitleEntries).labelsHidden()
                        .axLeaf("General.Toggle.AutoTitle")
                }
            }

            SettingsSection("Custom vocabulary") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Names or jargon, comma-separated",
                              text: $model.initialPrompt, axis: .vertical)
                        .lineLimit(2...6)
                        .textFieldStyle(.roundedBorder)
                        .axLeaf("General.TextField.InitialPrompt")
                    Text("A short list of names or jargon helps Whisper get unusual words right. Other engines ignore it.")
                        .font(DS.Font.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
            }
            ResetPaneButton(scope: .general)
        }
    }
}
