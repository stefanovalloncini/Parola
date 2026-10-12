import AppKit
import Carbon.HIToolbox
import SwiftUI

struct HotkeyRecorder: View {
    @Binding var keyCode: Int
    @Binding var modifierRawValue: Int
    var onRecordingChanged: ((Bool) -> Void)? = nil
    @State private var recording = false
    @State private var monitor: Any?
    @State private var rejection: HotkeyRejection?

    private var modifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: UInt(modifierRawValue))
            .intersection(.deviceIndependentFlagsMask)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            recorderButton
            if let rejection {
                hint(rejection.message)
            } else if !recording, let refusal = CarbonHotkeyRegistry.shared.health.refusal(keyCode: keyCode, modifiers: modifiers) {
                hint(refusal.message)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in stop() }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.trailing)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var recorderButton: some View {
        Button {
            if recording {
                stop()
            } else {
                start()
            }
        } label: {
            HStack(spacing: 8) {
                if recording {
                    Text("Press a key…")
                        .foregroundStyle(.secondary)
                } else {
                    Text(HotkeyDisplay.description(keyCode: keyCode, modifiers: modifiers))
                        .font(.system(.body, design: .rounded).weight(.medium))
                }
                Image(systemName: recording ? "stop.circle.fill" : "record.circle")
                    .foregroundStyle(recording ? .red : .secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                    .fill(.background.tertiary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                    .strokeBorder(recording ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: recording ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
        .onDisappear { stop() }
    }

    private func start() {
        guard !recording else { return }
        recording = true
        rejection = nil
        CarbonHotkeyRegistry.shared.suspend()
        onRecordingChanged?(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if event.type == .flagsChanged { return event }
            guard event.type == .keyDown else { return event }
            let pressedFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let code = Int(event.keyCode)
            if code == kVK_Escape, pressedFlags.intersection([.command, .control, .option, .shift]).isEmpty {
                stop()
                return nil
            }
            if let reason = HotkeyRules.rejection(keyCode: code, modifiers: pressedFlags) {
                rejection = reason
                return nil
            }
            keyCode = code
            modifierRawValue = Int(pressedFlags.rawValue)
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        guard recording else { return }
        rejection = nil
        recording = false
        CarbonHotkeyRegistry.shared.resume()
        onRecordingChanged?(false)
    }
}
