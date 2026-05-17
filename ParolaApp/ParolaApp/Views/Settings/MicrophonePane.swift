import SwiftUI
import AppKit
import ParolaCore

struct MicrophonePane: View {
    @EnvironmentObject var model: AppModel
    @State private var devices: [AudioInputDevice] = []
    @State private var preview: MicPreviewController?
    @State private var level: Float = 0
    @State private var startError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSection {
                SettingRow("Input device",
                           description: "Used for recording and the dictation fallback path.",
                           isFirst: true) {
                    Picker("", selection: $model.inputDeviceUID) {
                        Text("System default").tag("")
                        ForEach(devices) { device in
                            Text(device.isDefault ? "\(device.name) (default)" : device.name)
                                .tag(device.uid)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(minWidth: 220)
                }
                SettingRow("Live preview") {
                    VUMeter(level: level)
                        .frame(width: 220, height: 18)
                }
            }
            if let startError {
                MicErrorBanner(message: startError)
            }
            SettingHelper(text: "Streaming WhisperKit dictation always uses the system default mic. Other modes follow this picker.")
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

    private var hint: String {
        let lower = message.lowercased()
        if lower.contains("permission") || lower.contains("denied") || lower.contains("authoriz") {
            return "Open System Settings → Privacy & Security → Microphone and grant Parola access."
        }
        return "Pick a different device or reconnect the current one."
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
            if message.lowercased().contains("permission") || message.lowercased().contains("denied") || message.lowercased().contains("authoriz") {
                Button("Open System Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
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
