import SwiftUI
import AppKit
import AVFoundation
import ParolaCore

@MainActor
func openMicrophonePrivacySettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone") {
        NSWorkspace.shared.open(url)
    }
}

struct MicrophonePane: View {
    @Environment(AppModel.self) private var model
    @State private var devices: [AudioInputDevice] = []
    @State private var preview: MicPreviewController?
    @State private var previewMeter: LevelMeter?
    @State private var startError: String?
    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)

    var body: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 12) {
            if micStatus == .denied || micStatus == .restricted {
                micPermissionBanner
            }
            SettingsSection {
                SettingRow("Input device",
                           description: savedDeviceDisconnected
                               ? "This microphone is disconnected. Recordings use the system default until it returns."
                               : "Used for recording, dictation, and live captions.",
                           isFirst: true) {
                    Picker("", selection: $model.inputDeviceUID) {
                        Text("System default").tag("")
                        ForEach(devices) { device in
                            if device.isDefault {
                                Text("\(device.name) (default)").tag(device.uid)
                            } else {
                                Text(verbatim: device.name).tag(device.uid)
                            }
                        }
                        if savedDeviceDisconnected {
                            Text("Saved microphone (disconnected)").tag(model.inputDeviceUID)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(minWidth: 220, alignment: .trailing)
                    .axLeaf("Microphone.Picker.InputDevice")
                }
                SettingRow("Live preview",
                           description: "Input level from the selected device, so you can check it before recording.") {
                    LevelMeterReading(meter: previewMeter) { VUMeter(level: $0) }
                        .frame(width: 220, height: 18)
                }
                SettingRow("Auto-stop after",
                           description: "Stops a microphone or system-audio recording and transcribes it once this many minutes pass.") {
                    Picker("", selection: $model.recordingMaxMinutes) {
                        Text("Never").tag(0)
                        Text("5 min").tag(5)
                        Text("15 min").tag(15)
                        Text("30 min").tag(30)
                        Text("60 min").tag(60)
                        Text("120 min").tag(120)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 140, alignment: .trailing)
                    .axLeaf("Microphone.Picker.AutoStop")
                }
                SettingRow("Count-in",
                           description: "Counts down in the main window before recording starts. Press Esc to cancel.") {
                    Picker("", selection: $model.recordingCountInSeconds) {
                        Text("Off").tag(0)
                        Text("3 seconds").tag(3)
                        Text("5 seconds").tag(5)
                        Text("10 seconds").tag(10)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 140, alignment: .trailing)
                    .axLeaf("Microphone.Picker.CountIn")
                }
            }
            if let startError {
                MicErrorBanner(message: startError, status: micStatus)
            }

            SettingsSection("While recording") {
                SettingRow("Mute your Mac's sound while recording",
                           description: "So playback doesn't end up in the transcript. The sound comes back when the recording stops.",
                           isFirst: true) {
                    Toggle("", isOn: $model.autoMuteWhileRecording).labelsHidden()
                        .axLeaf("Microphone.Toggle.AutoMute")
                }
                SettingRow("Pause Music, Spotify, YouTube",
                           description: "Sends a pause command to whatever app is playing media when a mic recording starts, and resumes when it stops. System-audio recordings never pause media.") {
                    Toggle("", isOn: $model.autoPauseMediaWhileRecording).labelsHidden()
                        .axLeaf("Microphone.Toggle.AutoPauseMedia")
                }
            }
            SettingHelper(text: "Both apply to dictation too. A system audio recording never mutes your Mac.")

            if RecordControl.primarySource(features: model.features) != nil {
                RecordingControlsSection(pane: "Microphone")
            }
            ResetPaneButton(scope: .microphone)
        }
        .onAppear {
            micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            devices = AudioDevices.inputDevices()
            startPreview()
        }
        .onDisappear { stopPreview() }
        .onChange(of: model.inputDeviceUID) { _, _ in
            stopPreview()
            startPreview()
        }
    }

    /// A test host never opens the real microphone: an engine left waiting on CoreAudio there stalls every later CoreAudio call in the host.
    static func opensPreview(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        !TestHostSandbox.isTestHost(environment)
    }

    private var savedDeviceDisconnected: Bool {
        !model.inputDeviceUID.isEmpty && !devices.contains { $0.uid == model.inputDeviceUID }
    }

    private func startPreview() {
        stopPreview()
        startError = nil
        guard Self.opensPreview() else { return }
        let controller = MicPreviewController(deviceUID: model.preferredInputDeviceUID)
        preview = controller
        Task {
            do {
                let meter = try await controller.start()
                if preview === controller { previewMeter = meter }
            } catch {
                startError = error.localizedDescription
            }
        }
    }

    private func stopPreview() {
        let controller = preview
        preview = nil
        if let controller {
            Task { await controller.stop() }
        }
        previewMeter = nil
    }

    private var micPermissionBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "mic.slash.fill")
                .foregroundStyle(DS.Palette.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Microphone access is off")
                    .font(DS.Font.bodyStrong)
                Text("Parola needs the microphone to record and dictate.")
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Color.secondaryText)
            }
            Spacer()
            Button("Open System Settings…") { openMicrophonePrivacySettings() }
                .controlSize(.small)
                .axLeaf("Microphone.Button.OpenAccessSettings")
        }
        .padding(DS.Spacing.regular)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                .fill(DS.Palette.warning.opacity(0.12))
        )
    }
}

@MainActor
private final class MicPreviewController {
    let source: MicAudioSource
    private var started = false

    init(deviceUID: String?) {
        self.source = MicAudioSource(deviceUID: deviceUID, filePrefix: RecordingScratch.previewPrefix)
    }

    func start() async throws -> LevelMeter {
        try await source.start()
        started = true
        return source.levelMeter
    }

    func stop() async {
        if started {
            await source.cancel()
            started = false
        }
    }
}

struct MicErrorBanner: View {
    let message: String
    let status: AVAuthorizationStatus

    static func offersSystemSettings(for status: AVAuthorizationStatus) -> Bool {
        status == .denied || status == .restricted
    }

    private var hint: String {
        if Self.offersSystemSettings(for: status) {
            return String(localized: "Open System Settings → Privacy & Security → Microphone and grant Parola access.")
        }
        return String(localized: "Pick a different device or reconnect the current one.")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(DS.Palette.warning)
                Text("Couldn't open microphone")
                    .font(DS.Font.bodyStrong)
            }
            Text(message)
                .font(DS.Font.secondary)
                .foregroundStyle(DS.Color.secondaryText)
                .textSelection(.enabled)
            Text(hint)
                .font(DS.Font.secondary)
                .foregroundStyle(DS.Color.secondaryText)
            if Self.offersSystemSettings(for: status) {
                Button("Open System Settings…") { openMicrophonePrivacySettings() }
                .controlSize(.small)
                .axLeaf("Microphone.Button.OpenSystemSettings")
            }
        }
        .padding(DS.Spacing.regular)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                .fill(DS.Palette.warning.opacity(0.10))
        )
    }
}

private struct VUMeter: View {
    let level: Float

    private static let segments = 16

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 2) {
                ForEach(0..<Self.segments, id: \.self) { idx in
                    let threshold = Float(idx + 1) / Float(Self.segments)
                    let lit = level >= threshold
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(color(for: idx, lit: lit))
                        .frame(width: max(2, (proxy.size.width - CGFloat(Self.segments - 1) * 2) / CGFloat(Self.segments)))
                }
            }
        }
    }

    private func color(for idx: Int, lit: Bool) -> Color {
        if !lit { return Color.primary.opacity(0.10) }
        let fraction = Float(idx) / Float(Self.segments - 1)
        if fraction > 0.85 { return DS.Color.danger }
        if fraction > 0.65 { return DS.Palette.warning }
        return DS.Palette.success
    }
}

/// The switches for the take's menu bar item and pill: in the Microphone pane, or in Record Meetings for a build without one.
struct RecordingControlsSection: View {
    /// The pane it sits in, which its switches' identifiers start with.
    let pane: String
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        SettingsSection("Recording controls") {
            SettingRow("Show the recording in the menu bar",
                       description: "The time stays in the menu bar while you record, with the recording's controls in its menu.",
                       isFirst: true) {
                Toggle("", isOn: $model.showRecordingStatusItem).labelsHidden()
                    .accessibilityLabel("Show the recording in the menu bar")
                    .axLeaf("\(pane).Toggle.ShowRecordingStatusItem")
            }
            SettingRow("Show a floating recording pill when Parola is in the background",
                       description: "The time and a Stop button float over other apps. Drag the pill wherever you like.") {
                Toggle("", isOn: $model.showRecordingPill).labelsHidden()
                    .accessibilityLabel("Show a floating recording pill when Parola is in the background")
                    .axLeaf("\(pane).Toggle.ShowRecordingPill")
            }
        }
    }
}
