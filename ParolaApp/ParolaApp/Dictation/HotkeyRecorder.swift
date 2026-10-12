import AppKit
import SwiftUI

struct HotkeyRecorder: View {
    @Binding var keyCode: Int
    @Binding var modifierRawValue: Int
    var onRecordingChanged: ((Bool) -> Void)? = nil
    @State private var recording = false
    @State private var monitor: Any?

    private var modifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: UInt(modifierRawValue))
            .intersection(.deviceIndependentFlagsMask)
    }

    var body: some View {
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
        recording = true
        CarbonHotkeyRegistry.shared.setSuspended(true)
        onRecordingChanged?(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if event.type == .flagsChanged { return event }
            guard event.type == .keyDown else { return event }
            let pressedFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            keyCode = Int(event.keyCode)
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
        recording = false
        CarbonHotkeyRegistry.shared.setSuspended(false)
        onRecordingChanged?(false)
    }
}
