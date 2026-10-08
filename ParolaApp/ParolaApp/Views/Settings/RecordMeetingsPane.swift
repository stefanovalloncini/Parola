import SwiftUI
import ParolaCore

struct RecordMeetingsPane: View {
    @Environment(AppModel.self) private var model

    /// A build that records only meetings has no Microphone pane, so the take's switches come here.
    nonisolated static func showsRecordingControls(features: FeatureSet) -> Bool {
        !SettingsRoute.microphone.isVisible(features: features)
    }

    struct NeededPermissions: Equatable {
        var screenRecording: Bool
        var systemAudio: Bool
    }

    /// Only a detected meeting with app-only capture taps one app; every other system audio take records the whole mix.
    nonisolated static func neededPermissions(appOnly: Bool) -> NeededPermissions {
        NeededPermissions(screenRecording: true, systemAudio: appOnly)
    }

    var body: some View {
        @Bindable var model = model
        @Bindable var detector = model.meetingDetector
        let needed = Self.neededPermissions(appOnly: model.meetingCaptureAppOnly)
        return SettingsForm {
            SettingsSection("Permissions") {
                PermissionRow(
                    title: String(localized: "Screen & System Audio Recording"),
                    detail: String(localized: "Captures the system-wide audio mix. Every system audio recording uses it, except a detected meeting when “Record only the meeting app's audio” is on."),
                    granted: model.capturePermissions.screenRecordingGranted,
                    isFirst: true,
                    axID: "RecordMeetings.Button.GrantScreenRecording",
                    action: { model.capturePermissions.requestScreenRecording() },
                    actionLabel: String(localized: "Allow…"),
                    needed: needed.screenRecording
                )
                PermissionRow(
                    title: String(localized: "System Audio Recording Only"),
                    detail: String(localized: "Captures a single app's audio. Used for a detected meeting when “Record only the meeting app's audio” is on."),
                    granted: model.capturePermissions.systemAudioGranted,
                    isFirst: false,
                    axID: "RecordMeetings.Button.GrantSystemAudio",
                    action: { model.capturePermissions.requestSystemAudio() },
                    actionLabel: String(localized: "Allow…"),
                    needed: needed.systemAudio
                )
            }
            SettingsSection {
                SettingRow("Auto-detect meeting apps",
                           description: "Offers to record system audio when you open or switch to a meeting app like Zoom, Teams, or Webex. Meetings in a browser aren't detected. Parola only looks at which apps are running, and nothing leaves your Mac.",
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
                           description: "Keeps your voice on a track of its own beside the system audio, so the transcript marks what you said as Me.") {
                    Toggle("", isOn: $model.meetingRecordsMicrophone).labelsHidden()
                        .accessibilityLabel("Record my microphone in meetings")
                        .axLeaf("RecordMeetings.Toggle.Microphone")
                }
            }
            if Self.showsRecordingControls(features: model.features) {
                RecordingControlsSection(pane: "RecordMeetings")
            }
            ResetPaneButton(scope: .recordMeetings)
        }
        .onAppear { model.capturePermissions.refresh() }
    }
}
