import SwiftUI
import ParolaCore

struct RecordMeetingsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        @Bindable var detector = model.meetingDetector
        return VStack(alignment: .leading, spacing: 12) {
            SettingsSection("Permissions") {
                PermissionRow(
                    title: String(localized: "Screen Recording"),
                    detail: String(localized: "Captures the system-wide audio mix. Used unless “Record only the meeting app's audio” is on."),
                    granted: model.capturePermissions.screenRecordingGranted,
                    isFirst: true,
                    axID: "RecordMeetings.Button.GrantScreenRecording",
                    action: { model.capturePermissions.requestScreenRecording() },
                    actionLabel: String(localized: "Allow…")
                )
                PermissionRow(
                    title: String(localized: "System Audio Recording"),
                    detail: String(localized: "Captures a single app's audio. Used when “Record only the meeting app's audio” is on."),
                    granted: model.capturePermissions.systemAudioGranted,
                    isFirst: false,
                    axID: "RecordMeetings.Button.GrantSystemAudio",
                    action: { model.capturePermissions.requestSystemAudio() },
                    actionLabel: String(localized: "Allow…")
                )
            }
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
                SettingRow("Record my microphone in meetings",
                           description: "Keeps your voice on a track of its own beside the Mac audio, so the transcript marks what you said as Me.") {
                    Toggle("", isOn: $model.meetingRecordsMicrophone).labelsHidden()
                        .accessibilityLabel("Record my microphone in meetings")
                        .axLeaf("RecordMeetings.Toggle.Microphone")
                }
            }
            SettingHelper(text: "Parola watches running applications; nothing leaves your Mac.")
            ResetPaneButton(scope: .recordMeetings)
        }
        .onAppear { model.capturePermissions.refresh() }
    }
}
