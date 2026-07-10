import SwiftUI
import ParolaCore

struct RecordMeetingsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var detector = model.meetingDetector
        return VStack(alignment: .leading, spacing: 12) {
            SettingsSection {
                SettingRow("Auto-detect meeting apps",
                           description: "Offers to record system audio when a meeting app like Zoom, Teams, or Webex launches. Meetings in a browser aren't detected.",
                           isFirst: true) {
                    Toggle("", isOn: $detector.isEnabled).labelsHidden()
                        .axLeaf("RecordMeetings.Toggle.Enabled")
                }
            }
            SettingHelper(text: "Parola watches running applications; nothing leaves your Mac.")
            ResetPaneButton(scope: .recordMeetings)
        }
    }
}
