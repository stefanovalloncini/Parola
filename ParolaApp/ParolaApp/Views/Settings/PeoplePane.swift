import SwiftUI
import ParolaCore

struct PeoplePane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 16) {
            SettingsSection {
                SettingRow("Detect speakers by default",
                           description: "New transcriptions split the audio by speaker, so each one can be named.",
                           isFirst: true) {
                    Toggle("", isOn: $model.diarize).labelsHidden()
                        .axLeaf("People.Toggle.Diarize")
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
