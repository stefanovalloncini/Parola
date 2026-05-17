import SwiftUI
import ParolaCore

struct RecordMeetingsPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSection {
                SettingRow("Auto-detect meeting apps",
                           description: "Offer to record system audio when Zoom, Teams, Webex, or Meet launches.",
                           isFirst: true) {
                    Toggle("", isOn: $model.meetingDetector.isEnabled).labelsHidden()
                }
            }
            SettingHelper(text: "Parola watches running applications; nothing leaves your Mac.")
            ResetPaneButton(scope: .recordMeetings)
        }
    }
}
