import AppKit
import Carbon.HIToolbox
import Foundation
import ParolaCore

@MainActor
final class GlobalHotkeyMonitor: HotkeyMonitor {
    private let keyCode: Int
    private var globalMonitor: Any?
    private var isPressed: Bool = false

    init(keyCode: Int = Int(kVK_F5)) {
        self.keyCode = keyCode
    }

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

typealias F5HotkeyMonitor = GlobalHotkeyMonitor

enum DictationHotkey: Int, CaseIterable {
    case f5  = 96   // kVK_F5
    case f6  = 97
    case f7  = 98
    case f8  = 100
    case f9  = 101
    case f10 = 109
    case f13 = 105
    case f14 = 107
    case f15 = 113
    case f16 = 106
    case f17 = 64
    case f18 = 79
    case f19 = 80

    var displayName: String {
        switch self {
        case .f5:  return "F5"
        case .f6:  return "F6"
        case .f7:  return "F7"
        case .f8:  return "F8"
        case .f9:  return "F9"
        case .f10: return "F10"
        case .f13: return "F13"
        case .f14: return "F14"
        case .f15: return "F15"
        case .f16: return "F16"
        case .f17: return "F17"
        case .f18: return "F18"
        case .f19: return "F19"
        }
    }
}
