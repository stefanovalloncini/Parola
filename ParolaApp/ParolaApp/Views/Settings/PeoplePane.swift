import SwiftUI
import ParolaCore

struct PeoplePane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSection {
                SettingRow("Speakers",
                           description: "Names you give to Speaker 1, Speaker 2 stick across transcripts.",
                           isFirst: true) {
                    Text("Auto").foregroundStyle(.secondary)
                }
            }
            SettingHelper(text: "Rename a speaker from the transcript view to teach Parola who's who.")
        }
    }
}
