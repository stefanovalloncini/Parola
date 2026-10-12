import AppKit
import Carbon.HIToolbox
import Foundation
import ParolaCore
import ParolaDictation

struct CarbonHotkeyKey: Hashable {
    let keyCode: UInt32
    let modifiers: UInt32

    init(keyCode: Int, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = UInt32(truncatingIfNeeded: keyCode)
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        var mask = 0
        if flags.contains(.command) { mask |= cmdKey }
        if flags.contains(.shift) { mask |= shiftKey }
        if flags.contains(.option) { mask |= optionKey }
        if flags.contains(.control) { mask |= controlKey }
        self.modifiers = UInt32(mask)
    }
}

@MainActor
protocol CarbonHotkeyBackend: AnyObject {
    func register(_ key: CarbonHotkeyKey, id: UInt32) -> Bool
    func unregister(id: UInt32)
}

/// One OS registration per key combination, shared by every monitor that asks for it.
@MainActor
final class CarbonHotkeyRegistry {
    static let shared = CarbonHotkeyRegistry(backend: SystemCarbonHotkeyBackend())

    private struct Entry {
        let id: UInt32
        var isRegistered: Bool
        var handlers: [UUID: @Sendable (HotkeyEvent) -> Void]
    }

    private let backend: any CarbonHotkeyBackend
    private var entries: [CarbonHotkeyKey: Entry] = [:]
    private var keyByID: [UInt32: CarbonHotkeyKey] = [:]
    private var nextID: UInt32 = 1
    private var isSuspended = false

    init(backend: any CarbonHotkeyBackend) {
        self.backend = backend
    }

    var registrationCount: Int { entries.values.filter(\.isRegistered).count }

    func add(_ key: CarbonHotkeyKey, handler: @escaping @Sendable (HotkeyEvent) -> Void) -> UUID? {
        let token = UUID()
        if var entry = entries[key] {
            entry.handlers[token] = handler
            entries[key] = entry
            return token
        }
        let id = nextID
        let registered = !isSuspended && backend.register(key, id: id)
        guard registered || isSuspended else { return nil }
        nextID += 1
        entries[key] = Entry(id: id, isRegistered: registered, handlers: [token: handler])
        keyByID[id] = key
        return token
    }

    func remove(_ key: CarbonHotkeyKey, token: UUID) {
        guard var entry = entries[key] else { return }
        entry.handlers[token] = nil
        if entry.handlers.isEmpty {
            if entry.isRegistered { backend.unregister(id: entry.id) }
            entries[key] = nil
            keyByID[entry.id] = nil
        } else {
            entries[key] = entry
        }
    }

    /// While a shortcut is being recorded, the combo being pressed must reach the recorder, not trigger the old binding.
    func setSuspended(_ suspended: Bool) {
        guard suspended != isSuspended else { return }
        isSuspended = suspended
        for (key, var entry) in entries {
            if suspended, entry.isRegistered {
                backend.unregister(id: entry.id)
                entry.isRegistered = false
            } else if !suspended, !entry.isRegistered {
                entry.isRegistered = backend.register(key, id: entry.id)
            }
            entries[key] = entry
        }
    }

    func deliver(id: UInt32, event: HotkeyEvent) {
        guard let key = keyByID[id], let entry = entries[key] else { return }
        for handler in entry.handlers.values { handler(event) }
    }
}

@MainActor
private final class SystemCarbonHotkeyBackend: CarbonHotkeyBackend {
    private static let signature: OSType = 0x50524C41
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlerInstalled = false

    func register(_ key: CarbonHotkeyKey, id: UInt32) -> Bool {
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            key.keyCode, key.modifiers, EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(), 0, &ref
        )
        guard status == noErr, let ref else { return false }
        refs[id] = ref
        return true
    }

    func unregister(id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            guard status == noErr else { return status }
            let kind: HotkeyEvent = GetEventKind(event) == UInt32(kEventHotKeyPressed) ? .press : .release
            MainActor.assumeIsolated {
                CarbonHotkeyRegistry.shared.deliver(id: hotKeyID.id, event: kind)
            }
            return noErr
        }, types.count, &types, nil, nil)
    }
}

@MainActor
final class GlobalHotkeyMonitor: HotkeyMonitor {
    private let key: CarbonHotkeyKey
    private let registry: CarbonHotkeyRegistry
    private var token: UUID?
    private var isPressed: Bool = false

    init(
        keyCode: Int = Int(kVK_F5),
        modifiers: NSEvent.ModifierFlags = [],
        registry: CarbonHotkeyRegistry = .shared
    ) {
        self.key = CarbonHotkeyKey(keyCode: keyCode, modifiers: modifiers)
        self.registry = registry
    }

    isolated deinit {
        unregister()
    }

    nonisolated func start(handler: @escaping @Sendable (HotkeyEvent) -> Void) async {
        await MainActor.run { self.register(handler: handler) }
    }

    nonisolated func stop() async {
        await MainActor.run { self.unregister() }
    }

    var isRegistered: Bool { token != nil }

    private func register(handler: @escaping @Sendable (HotkeyEvent) -> Void) {
        unregister()
        token = registry.add(key) { [weak self] event in
            MainActor.assumeIsolated { self?.process(event, handler: handler) }
        }
    }

    /// Key repeat and a release without a press never reach the handler.
    private func process(_ event: HotkeyEvent, handler: @Sendable (HotkeyEvent) -> Void) {
        switch event {
        case .press:
            guard !isPressed else { return }
            isPressed = true
        case .release:
            guard isPressed else { return }
            isPressed = false
        }
        handler(event)
    }

    private func unregister() {
        if let token { registry.remove(key, token: token) }
        token = nil
        isPressed = false
    }
}

typealias F5HotkeyMonitor = GlobalHotkeyMonitor

/// Hears no keys; presses reach the coordinator only through its simulate calls.
final class SilentHotkeyMonitor: HotkeyMonitor {
    func start(handler: @escaping @Sendable (HotkeyEvent) -> Void) async {}
    func stop() async {}
}

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
