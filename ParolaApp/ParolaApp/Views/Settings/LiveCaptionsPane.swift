import SwiftUI
import ParolaCore

struct LiveCaptionsPane: View {
    @Environment(AppModel.self) private var model
    @Environment(LiveCaptionsController.self) private var liveCaptions

    var body: some View {
        @Bindable var model = model
        SettingsForm {
            Section {
                SettingRow("Listen to",
                           description: "Pick an app to caption only its sound.") {
                    Picker("", selection: $model.liveCaptionsSourceRaw) {
                        Text("Microphone").tag("microphone")
                        Text("System Audio").tag("systemAudio")
                        let choices = model.captionApps.choices(saved: model.liveCaptionsSourceRaw)
                        if !choices.isEmpty { Divider() }
                        ForEach(choices) { Text(verbatim: $0.title).tag($0.setting) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(minWidth: 220, alignment: .trailing)
                    .axLeaf("LiveCaptions.Picker.Source")
                }
                if let permission = Self.neededPermission(for: model.liveCaptionsSource) {
                    permissionRow(permission)
                }
                SettingRow("Live captions",
                           descriptionVerbatim: model.liveCaptionsUnavailableReason ?? String(localized: "Also in the Captions menu (⇧⌘L).")) {
                    Button(liveCaptions.isActive ? "Stop Live Captions" : "Start Live Captions") {
                        model.toggleLiveCaptions()
                    }
                    .disabled(!liveCaptions.isActive && model.liveCaptionsUnavailableReason != nil)
                    .axLeaf("LiveCaptions.Button.StartStop")
                }
                SettingRow("Translate to English",
                           description: "Translate the captions into English as they appear.") {
                    Toggle("", isOn: $model.liveCaptionsTranslate)
                        .labelsHidden()
                        .axLeaf("LiveCaptions.Toggle.Translate")
                }
            } footer: {
                VStack(alignment: .leading, spacing: DS.Spacing.hair) {
                    if let warning = model.translateMismatchWarning {
                        SettingsWarning(warning)
                            .axLeaf("LiveCaptions.Label.TranslateWarning")
                    }
                    Text("Live captions show the words in a floating panel that stays above other windows.")
                        .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            ResetPaneButton(scope: .liveCaptions)
        }
        .onAppear { model.capturePermissions.refresh() }
    }

    /// The one privacy permission a source needs; the microphone's lives in its own pane.
    nonisolated static func neededPermission(for source: CaptionSource) -> RecordingSession.Permission? {
        switch source {
        case .microphone: nil
        case .systemAudio: .screenRecording
        case .app: .systemAudioRecording
        }
    }

    @ViewBuilder
    private func permissionRow(_ permission: RecordingSession.Permission) -> some View {
        switch permission {
        case .systemAudioRecording:
            PermissionRow(
                title: String(localized: "System Audio Recording Only"),
                detail: String(localized: "Lets Live Captions hear one app's audio."),
                granted: model.capturePermissions.systemAudioGranted,
                axID: "LiveCaptions.Button.GrantSystemAudio",
                action: { model.capturePermissions.requestSystemAudio() },
                actionLabel: String(localized: "Allow…")
            )
        default:
            PermissionRow(
                title: String(localized: "Screen & System Audio Recording"),
                detail: String(localized: "Lets Live Captions hear the whole Mac's audio."),
                granted: model.capturePermissions.screenRecordingGranted,
                axID: "LiveCaptions.Button.GrantScreenRecording",
                action: { model.capturePermissions.requestScreenRecording() },
                actionLabel: String(localized: "Allow…")
            )
        }
    }
}
