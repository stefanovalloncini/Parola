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
                SettingRow("Show Parola in",
                           description: "The menu bar item carries quick actions and recent transcripts. Without the Dock icon Parola stays out of ⌘-Tab.") {
                    Picker("", selection: $model.appVisibilityMode) {
                        ForEach(AppVisibilityMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 180, alignment: .trailing)
                    .axLeaf("General.Picker.AppVisibility")
                }
            }

            SettingsSection("Files you add") {
                SettingRow("When a file was already transcribed",
                           description: "Parola recognises a file by its contents, so a renamed copy counts as the same recording. In a batch, “Ask me” skips the file.",
                           isFirst: true) {
                    Picker("", selection: $model.duplicateImportPolicy) {
                        ForEach(DuplicateImportPolicy.allCases) { policy in
                            Text(policy.label).tag(policy)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 180, alignment: .trailing)
                    .axLeaf("General.Picker.DuplicateImportPolicy")
                }
            }

            SettingsSection("Every transcript") {
                SettingRow("Highlight the word being spoken",
                           description: "Bolds and tints the current word as audio plays.",
                           isFirst: true) {
                    Toggle("", isOn: $model.karaokeHighlight)
                        .labelsHidden()
                        .axLeaf("General.Toggle.KaraokeHighlight")
                }
                if Self.showsStreamMicrophoneRow(features: model.features) {
                    SettingRow("Stream microphone in real time",
                               description: "Transcript appears as you speak — Whisper models only; other engines record the take first. Off always records first, then transcribes.") {
                        Toggle("", isOn: $model.useStreaming).labelsHidden()
                            .axLeaf("General.Toggle.UseStreaming")
                    }
                }
                SettingRow("Always open transcripts in a new window",
                           description: "Double-clicking a library row opens its own window instead of taking over the main one. Hold Option to open a window either way.") {
                    Toggle("", isOn: $model.openEntriesInNewWindow).labelsHidden()
                        .axLeaf("General.Toggle.OpenEntriesInNewWindow")
                }
                SettingRow("Play a sound when a transcription finishes",
                           description: "Plays the system Glass sound as the transcript lands in your library. A batch plays it once, at the end.") {
                    Toggle("", isOn: $model.playSoundWhenFinished).labelsHidden()
                        .axLeaf("General.Toggle.PlaySoundWhenFinished")
                }
            }

            SettingsSection("Library cards") {
                SettingRow("Generate an AI title and summary",
                           description: "Writes a short title and a one-line summary from the transcript, on device, when a transcription finishes.",
                           isFirst: true) {
                    Toggle("", isOn: $model.generatesCardMetadata).labelsHidden()
                        .axLeaf("General.Toggle.GenerateCardMetadata")
                }
                SettingRow("Show the AI title instead of the file name",
                           description: "Card and row titles use the generated title when one exists.") {
                    Toggle("", isOn: $model.showAITitles).labelsHidden()
                        .axLeaf("General.Toggle.ShowAITitles")
                }
                SettingRow("Show the AI summary instead of the first lines",
                           description: "Row previews use the generated summary when one exists.") {
                    Toggle("", isOn: $model.showAISummaries).labelsHidden()
                        .axLeaf("General.Toggle.ShowAISummaries")
                }
                SettingRow("Title instructions",
                           description: "Replaces the built-in title instructions when set.") {
                    TextField("Title instructions", text: $model.customTitlePrompt,
                              prompt: Text("For example, mention the client's name."), axis: .vertical)
                        .labelsHidden()
                        .lineLimit(1...3)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                        .axLeaf("General.TextField.CustomTitlePrompt")
                }
                SettingRow("Summary instructions",
                           description: "Replaces the built-in summary instructions when set.") {
                    TextField("Summary instructions", text: $model.customSummaryPrompt,
                              prompt: Text("For example, keep numbers and dates."), axis: .vertical)
                        .labelsHidden()
                        .lineLimit(1...3)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                        .axLeaf("General.TextField.CustomSummaryPrompt")
                }
            }
            ResetPaneButton(scope: .general)
        }
    }
}
