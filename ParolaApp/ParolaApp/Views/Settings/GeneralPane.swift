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

            SettingsSection("Every transcript") {
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
                SettingRow("Always open transcripts in a new window",
                           description: "Double-clicking a library row opens its own window instead of taking over the main one. Hold Option to open a window either way.") {
                    Toggle("", isOn: $model.openEntriesInNewWindow).labelsHidden()
                        .axLeaf("General.Toggle.OpenEntriesInNewWindow")
                }
                if let warning = model.diarizeMismatchWarning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(DS.Font.secondary)
                        .foregroundStyle(DS.Color.warningText)
                        .padding(.top, DS.Spacing.hair)
                        .axLeaf("General.Label.DiarizeWarning")
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
            }

            SettingsSection("Custom instructions") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("For example, mention the client's name.",
                              text: $model.customTitlePrompt, axis: .vertical)
                        .lineLimit(1...3)
                        .textFieldStyle(.roundedBorder)
                        .axLeaf("General.TextField.CustomTitlePrompt")
                    Text("Replaces the built-in title instructions when set.")
                        .font(DS.Font.secondary)
                        .foregroundStyle(DS.Color.secondaryText)
                    TextField("For example, keep numbers and dates.",
                              text: $model.customSummaryPrompt, axis: .vertical)
                        .lineLimit(1...3)
                        .textFieldStyle(.roundedBorder)
                        .axLeaf("General.TextField.CustomSummaryPrompt")
                    Text("Replaces the built-in summary instructions when set.")
                        .font(DS.Font.secondary)
                        .foregroundStyle(DS.Color.secondaryText)
                }
                .padding(DS.Spacing.medium)
            }

            SettingsSection("Custom vocabulary") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Names or jargon, comma-separated",
                              text: $model.initialPrompt, axis: .vertical)
                        .lineLimit(2...6)
                        .textFieldStyle(.roundedBorder)
                        .axLeaf("General.TextField.InitialPrompt")
                    Text("A short list of names or jargon helps Whisper get unusual words right. Other engines ignore it.")
                        .font(DS.Font.secondary)
                        .foregroundStyle(DS.Color.secondaryText)
                }
                .padding(DS.Spacing.medium)
            }
            ResetPaneButton(scope: .general)
        }
    }
}
