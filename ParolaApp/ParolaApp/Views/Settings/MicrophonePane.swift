import SwiftUI
import AppKit
import ParolaCore

struct MicrophonePane: View {
    @Environment(AppModel.self) private var model
    @State private var devices: [AudioInputDevice] = []
    @State private var preview: MicPreviewController?
    @State private var level: Float = 0
    @State private var startError: String?

    var body: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 12) {
            SettingsSection {
                SettingRow("Input device",
                           description: "Used for recording and the dictation fallback path.",
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
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(minWidth: 220)
                    .axLeaf("Microphone.Picker.InputDevice")
                }
                SettingRow("Live preview") {
                    VUMeter(level: level)
                        .frame(width: 220, height: 18)
                }
                SettingRow("Auto-stop after",
                           description: "Stops a microphone or system-audio recording and transcribes it once this many minutes pass.") {
                    HStack(spacing: 6) {
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
                        .frame(width: 120)
                        .axLeaf("Microphone.Picker.AutoStop")
                    }
                }
                SettingRow("Count-in",
                           description: "Shows a 3-2-1 countdown before recording starts. Press Esc to cancel.") {
                    Picker("", selection: $model.recordingCountInSeconds) {
                        Text("Off").tag(0)
                        Text("3 seconds").tag(3)
                        Text("5 seconds").tag(5)
                        Text("10 seconds").tag(10)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 140)
                    .axLeaf("Microphone.Picker.CountIn")
                }
            }
            if let startError {
                MicErrorBanner(message: startError)
            }
            SettingHelper(text: "Streaming WhisperKit dictation always uses the system default mic. Other modes follow this picker.")

            SettingsSection("While recording") {
                SettingRow("Mute system audio",
                           description: "Mutes the default output device while recording from the microphone, so playback doesn't leak into your transcript. Restores the previous mute state when recording stops.",
                           isFirst: true) {
                    Toggle("", isOn: $model.autoMuteWhileRecording).labelsHidden()
                        .axLeaf("Microphone.Toggle.AutoMute")
                }
                SettingRow("Pause Music, Spotify, YouTube",
                           description: "Sends a pause command to whatever app is playing media when recording starts, and resumes when it stops.") {
                    Toggle("", isOn: $model.autoPauseMediaWhileRecording).labelsHidden()
                        .axLeaf("Microphone.Toggle.AutoPauseMedia")
                }
            }
            SettingHelper(text: "Both apply to dictation too. Mute is skipped when the recording source is system audio.")
            ResetPaneButton(scope: .microphone)
        }
        .onAppear {
            devices = AudioDevices.inputDevices()
            startPreview()
        }
        .onDisappear { stopPreview() }
        .onChange(of: model.inputDeviceUID) { _, _ in
            stopPreview()
            startPreview()
        }
    }

    private func startPreview() {
        stopPreview()
        startError = nil
        let controller = MicPreviewController(deviceUID: model.preferredInputDeviceUID)
        preview = controller
        Task {
            do {
                let stream = try await controller.start()
                for await value in stream {
                    if abs(level - value) > 0.01 { level = value }
                }
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
        level = 0
    }
}

@MainActor
private final class MicPreviewController {
    let source: MicAudioSource
    private var started = false

    init(deviceUID: String?) {
        self.source = MicAudioSource(deviceUID: deviceUID)
    }

    func start() async throws -> AsyncStream<Float> {
        try await source.start()
        started = true
        return await source.levels()
    }

    func stop() async {
        if started {
            await source.cancel()
            started = false
        }
    }
}

private struct MicErrorBanner: View {
    let message: String

    private var looksLikePermissionError: Bool {
        let l = message.lowercased()
        return l.contains("permission") || l.contains("denied") || l.contains("authoriz")
    }

    private var hint: String {
        if looksLikePermissionError {
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
                    .font(.callout.weight(.medium))
            }
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
            if looksLikePermissionError {
                Button("Open System Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
                .axLeaf("Microphone.Button.OpenSystemSettings")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
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
        if fraction > 0.85 { return Color.red }
        if fraction > 0.65 { return DS.Palette.warning }
        return DS.Palette.success
    }
}
