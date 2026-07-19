import SwiftUI
import ParolaCore

struct RecordMeetingsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        @Bindable var detector = model.meetingDetector
        return VStack(alignment: .leading, spacing: 12) {
            SettingsSection {
                SettingRow("Auto-detect meeting apps",
                           description: "Offers to record system audio when you open or switch to a meeting app like Zoom, Teams, or Webex. Meetings in a browser aren't detected.",
                           isFirst: true) {
                    Toggle("", isOn: $detector.isEnabled).labelsHidden()
                        .axLeaf("RecordMeetings.Toggle.Enabled")
                }
                SettingRow("Record only the meeting app's audio",
                           description: "Leaves notification sounds and other apps out of the recording. Skip this if the meeting app plays audio through a helper the recording could miss.") {
                    Toggle("", isOn: $model.meetingCaptureAppOnly).labelsHidden()
                        .axLeaf("RecordMeetings.Toggle.AppOnly")
                }
            }
            SettingHelper(text: "Parola watches running applications; nothing leaves your Mac.")
            ResetPaneButton(scope: .recordMeetings)
        }
    }
}
