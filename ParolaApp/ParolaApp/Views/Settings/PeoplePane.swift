import SwiftUI
import ParolaCore

struct PeoplePane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        return SettingsForm {
            SettingsSection {
                SettingRow("Detect speakers",
                           description: "Speaker detection is in Transcription Defaults, with the other settings for new transcriptions.") {
                    Button("Open Transcription Defaults") {
                        model.settingsPane = SettingsRoute.transcriptionDefaults.rawValue
                    }
                    .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
                    .axLeaf("People.Button.TranscriptionDefaults")
                }
                SettingRow("Show most used people in the sidebar",
                           description: "Puts the five people you assign most under Library, each one a filter.") {
                    Toggle("", isOn: $model.showMostUsedPeople).labelsHidden()
                        .axLeaf("People.Toggle.ShowInSidebar")
                }
            }

            PeopleDirectoryList()

            SettingHelper(text: "A person carries a colour and a name across every transcript they speak in. Renaming or merging rewrites the name in the transcripts that point at them.")

            ResetPaneButton(scope: .people)
        }
    }
}
