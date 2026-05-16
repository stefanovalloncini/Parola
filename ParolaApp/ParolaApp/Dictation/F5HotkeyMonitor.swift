import AppKit
import Carbon.HIToolbox
import Foundation
import ParolaCore

@MainActor
final class F5HotkeyMonitor: HotkeyMonitor {
    private let keyCode: Int = Int(kVK_F5)
    private var globalMonitor: Any?
    private var isPressed: Bool = false

    nonisolated func start(handler: @escaping @Sendable (HotkeyEvent) -> Void) async {
        await installMonitor(handler: handler)
    }

    nonisolated func stop() async {
        await removeMonitor()
    }

    @MainActor
    private func installMonitor(handler: @escaping @Sendable (HotkeyEvent) -> Void) async {
        await removeMonitor()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard event.keyCode == self.keyCode else { return }
                switch event.type {
                case .keyDown:
                    if !self.isPressed {
                        self.isPressed = true
                        handler(.press)
                    }
                case .keyUp:
                    if self.isPressed {
                        self.isPressed = false
                        handler(.release)
                    }
                default: break
                }
            }
        }
    }

    @MainActor
    private func removeMonitor() async {
        if let m = globalMonitor {
            NSEvent.removeMonitor(m)
            globalMonitor = nil
        }
        isPressed = false
    }
}
