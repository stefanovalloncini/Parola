import SwiftUI
import ParolaCore

struct MicrophonePane: View {
    @EnvironmentObject var model: AppModel
    @State private var devices: [AudioInputDevice] = []
    @State private var preview: MicPreviewController?
    @State private var level: Float = 0

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
            SettingHelper(text: "Streaming WhisperKit dictation always uses the system default mic. Other modes follow this picker.")
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
        let controller = MicPreviewController(deviceUID: model.preferredInputDeviceUID) { newLevel in
            Task { @MainActor in
                if abs(self.level - newLevel) > 0.01 { self.level = newLevel }
            }
        }
        preview = controller
        Task { await controller.start() }
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
    let onLevel: @Sendable (Float) -> Void
    var levelTask: Task<Void, Never>?
    var started = false

    init(deviceUID: String?, onLevel: @escaping @Sendable (Float) -> Void) {
        self.source = MicAudioSource(deviceUID: deviceUID)
        self.onLevel = onLevel
    }

    func start() async {
        do {
            try await source.start()
            started = true
        } catch {
            return
        }
        let stream = await source.levels()
        let cb = onLevel
        levelTask = Task {
            for await value in stream {
                cb(value)
            }
        }
    }

    func stop() async {
        levelTask?.cancel()
        levelTask = nil
        if started {
            await source.cancel()
            started = false
        }
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
