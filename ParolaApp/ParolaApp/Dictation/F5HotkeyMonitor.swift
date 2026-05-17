import AppKit
import Carbon.HIToolbox
import Foundation
import ParolaCore

@MainActor
final class GlobalHotkeyMonitor: HotkeyMonitor {
    private let keyCode: Int
    private let modifierMask: NSEvent.ModifierFlags
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isPressed: Bool = false

    init(keyCode: Int = Int(kVK_F5), modifiers: NSEvent.ModifierFlags = []) {
        self.keyCode = keyCode
        self.modifierMask = modifiers.intersection(.deviceIndependentFlagsMask)
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
        let mask: NSEvent.EventTypeMask = [.keyDown, .keyUp]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.process(event: event, handler: handler)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.process(event: event, handler: handler)
            }
            return event
        }
    }

    private func process(event: NSEvent, handler: @Sendable (HotkeyEvent) -> Void) {
        guard event.keyCode == self.keyCode else { return }
        let needed = self.modifierMask
        if !needed.isEmpty {
            let pressed = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard pressed.contains(needed) else { return }
        }
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

    @MainActor
    private func removeMonitor() async {
        if let m = globalMonitor {
            NSEvent.removeMonitor(m)
            globalMonitor = nil
        }
        if let m = localMonitor {
            NSEvent.removeMonitor(m)
            localMonitor = nil
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

enum HotkeyDisplay {
    static func description(keyCode: Int, modifiers: NSEvent.ModifierFlags) -> String {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        var parts: [String] = []
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option) { parts.append("⌥") }
        if flags.contains(.shift) { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }
        parts.append(keyName(forKeyCode: keyCode))
        return parts.joined()
    }

    static func keyName(forKeyCode keyCode: Int) -> String {
        if let preset = DictationHotkey(rawValue: keyCode) {
            return preset.displayName
        }
        switch keyCode {
        case Int(kVK_Space): return "Space"
        case Int(kVK_Return): return "↩"
        case Int(kVK_Escape): return "⎋"
        case Int(kVK_Tab): return "⇥"
        case Int(kVK_Delete): return "⌫"
        case Int(kVK_LeftArrow): return "←"
        case Int(kVK_RightArrow): return "→"
        case Int(kVK_UpArrow): return "↑"
        case Int(kVK_DownArrow): return "↓"
        case Int(kVK_Home): return "Home"
        case Int(kVK_End): return "End"
        case Int(kVK_PageUp): return "Page Up"
        case Int(kVK_PageDown): return "Page Down"
        case Int(kVK_F1): return "F1"
        case Int(kVK_F2): return "F2"
        case Int(kVK_F3): return "F3"
        case Int(kVK_F4): return "F4"
        case Int(kVK_F11): return "F11"
        case Int(kVK_F12): return "F12"
        default: break
        }
        if let character = NSEvent.character(forKeyCode: keyCode) {
            return character.uppercased()
        }
        return "Key \(keyCode)"
    }
}

private extension NSEvent {
    static func character(forKeyCode keyCode: Int) -> String? {
        let source = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
        guard let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let dataRef = unsafeBitCast(layoutData, to: CFData.self)
        let layout = unsafeBitCast(CFDataGetBytePtr(dataRef), to: UnsafePointer<UCKeyboardLayout>.self)
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var realLength = 0
        let status = UCKeyTranslate(
            layout,
            UInt16(keyCode),
            UInt16(kUCKeyActionDisplay),
            0,
            UInt32(LMGetKbdType()),
            UInt32(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            chars.count,
            &realLength,
            &chars
        )
        guard status == noErr, realLength > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: realLength)
    }
}
