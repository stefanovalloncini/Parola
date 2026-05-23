import SwiftUI
import ParolaCore

struct RecordMeetingsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var detector = model.meetingDetector
        return VStack(alignment: .leading, spacing: 12) {
            SettingsSection {
                SettingRow("Auto-detect meeting apps",
                           description: "Offer to record system audio when Zoom, Teams, Webex, or Meet launches.",
                           isFirst: true) {
                    Toggle("", isOn: $detector.isEnabled).labelsHidden()
                }
            }
            SettingHelper(text: "Parola watches running applications; nothing leaves your Mac.")
            ResetPaneButton(scope: .recordMeetings)
        }
    }
}
