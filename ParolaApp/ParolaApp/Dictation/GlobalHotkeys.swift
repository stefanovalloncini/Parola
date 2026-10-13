import AppKit
import Carbon.HIToolbox
import Foundation
import Observation
import ParolaCore
import ParolaDictation

enum HotkeyRejection: Equatable {
    case optionOnly
    case needsCommandOrControl
    case reserved

    var message: String {
        switch self {
        case .optionOnly: String(localized: "Hotkey.Reject.OptionOnly")
        case .needsCommandOrControl: String(localized: "Hotkey.Reject.NeedsModifier")
        case .reserved: String(localized: "Hotkey.Reject.Reserved")
        }
    }
}

enum HotkeyRules {
    static let functionKeyCodes: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    private static let reservedWithCommand: Set<Int> = [
        kVK_ANSI_W, kVK_ANSI_Q, kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_X, kVK_ANSI_Z, kVK_ANSI_A, kVK_Space, kVK_Tab,
        kVK_ANSI_S, kVK_ANSI_F, kVK_ANSI_T, kVK_ANSI_N, kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_H, kVK_ANSI_M, kVK_ANSI_Comma,
    ]

    /// ⌘ alone or ⌘⇧ with a key every app already uses.
    static func isReserved(keyCode: Int, command: Bool, control: Bool, option: Bool) -> Bool {
        command && !control && !option && reservedWithCommand.contains(keyCode)
    }

    static func isOptionOnly(command: Bool, control: Bool, option: Bool) -> Bool {
        option && !command && !control
    }

    static func isFunctionKey(_ keyCode: Int) -> Bool { functionKeyCodes.contains(keyCode) }

    static func rejection(keyCode: Int, modifiers: NSEvent.ModifierFlags) -> HotkeyRejection? {
        let flags = modifiers.intersection([.command, .control, .option, .shift])
        let command = flags.contains(.command), control = flags.contains(.control), option = flags.contains(.option)
        if isOptionOnly(command: command, control: control, option: option) { return .optionOnly }
        if isFunctionKey(keyCode) { return nil }
        if !command, !control { return .needsCommandOrControl }
        if isReserved(keyCode: keyCode, command: command, control: control, option: option) { return .reserved }
        return nil
    }
}

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

    /// macOS 15+ accepts these registrations but never delivers them, so they are served by key monitors instead.
    var isOptionOnly: Bool {
        let optionOrShift = UInt32(optionKey | shiftKey)
        return modifiers & UInt32(optionKey) != 0 && modifiers & ~optionOrShift == 0
    }

    var isReserved: Bool {
        HotkeyRules.isReserved(
            keyCode: Int(keyCode),
            command: modifiers & UInt32(cmdKey) != 0,
            control: modifiers & UInt32(controlKey) != 0,
            option: modifiers & UInt32(optionKey) != 0
        )
    }

    /// Carbon would consume a bare letter or Escape system-wide, and a reserved ⌘ key would break every app.
    var isPermitted: Bool {
        guard !isReserved else { return false }
        return HotkeyRules.isFunctionKey(Int(keyCode)) || modifiers & UInt32(cmdKey | controlKey | optionKey) != 0
    }
}

enum HotkeyRefusal {
    case byParola
    case bySystem
    case monitorOnly

    var message: String {
        switch self {
        case .byParola: String(localized: "Hotkey.Refused.Parola")
        case .bySystem: String(localized: "Hotkey.Refused.System")
        case .monitorOnly: String(localized: "Hotkey.Refused.OptionOnly")
        }
    }

    var needsAccessibility: Bool { self != .byParola }
}

@MainActor
@Observable
final class HotkeyHealth {
    private(set) var refused: [CarbonHotkeyKey: HotkeyRefusal] = [:]

    func refusal(keyCode: Int, modifiers: NSEvent.ModifierFlags) -> HotkeyRefusal? {
        refused[CarbonHotkeyKey(keyCode: keyCode, modifiers: modifiers)]
    }

    func isRefused(keyCode: Int, modifiers: NSEvent.ModifierFlags) -> Bool {
        refusal(keyCode: keyCode, modifiers: modifiers) != nil
    }

    fileprivate func set(_ key: CarbonHotkeyKey, _ refusal: HotkeyRefusal?) {
        refused[key] = refusal
    }
}

@MainActor
protocol CarbonHotkeyBackend: AnyObject {
    func register(_ key: CarbonHotkeyKey, id: UInt32) -> OSStatus
    func unregister(id: UInt32)
}

/// One OS registration per key combination, shared by every monitor that asks for it.
@MainActor
final class CarbonHotkeyRegistry {
    static let shared = CarbonHotkeyRegistry(backend: SystemCarbonHotkeyBackend())

    enum Outcome: Equatable {
        case registered
        case suspended
        case refusedByOS(OSStatus)
        case monitorOnly
        case refusedByPolicy
    }

    struct Addition {
        let token: UUID?
        let outcome: Outcome
    }

    private struct Entry {
        let id: UInt32
        var status: OSStatus?
        var monitorOnly = false
        var handlers: [UUID: @Sendable (HotkeyEvent) -> Void]
        var refusalHandlers: [UUID: @MainActor () -> Void] = [:]
        var isRegistered: Bool { status == noErr }
    }

    let health = HotkeyHealth()
    private let backend: any CarbonHotkeyBackend
    private var entries: [CarbonHotkeyKey: Entry] = [:]
    private var keyByID: [UInt32: CarbonHotkeyKey] = [:]
    private var nextID: UInt32 = 1
    private var suspensions = 0

    init(backend: any CarbonHotkeyBackend) {
        self.backend = backend
    }

    var isSuspended: Bool { suspensions > 0 }

    func add(
        _ key: CarbonHotkeyKey,
        onRefusalOnResume: (@MainActor () -> Void)? = nil,
        handler: @escaping @Sendable (HotkeyEvent) -> Void
    ) -> Addition {
        guard key.isPermitted else {
            ParolaLog.notice(.dictation, "hotkey refused: key \(Int(key.keyCode)) with modifiers \(Int(key.modifiers)) is bare or reserved")
            health.set(key, .byParola)
            return Addition(token: nil, outcome: .refusedByPolicy)
        }
        let token = UUID()
        var entry = entries[key] ?? makeEntry(for: key)
        entry.handlers[token] = handler
        entry.refusalHandlers[token] = onRefusalOnResume
        if key.isOptionOnly {
            entry.monitorOnly = true
            health.set(key, .monitorOnly)
        } else if !isSuspended, !entry.isRegistered {
            attemptRegistration(of: key, entry: &entry)
        }
        entries[key] = entry
        return Addition(token: token, outcome: outcome(of: entry))
    }

    func remove(_ key: CarbonHotkeyKey, token: UUID) {
        guard var entry = entries[key] else { return }
        entry.handlers[token] = nil
        entry.refusalHandlers[token] = nil
        if entry.handlers.isEmpty {
            if entry.isRegistered { backend.unregister(id: entry.id) }
            entries[key] = nil
            keyByID[entry.id] = nil
            health.set(key, nil)
        } else {
            entries[key] = entry
        }
    }

    /// While a shortcut is being recorded, the combo being pressed must reach the recorder, not trigger the old binding.
    func suspend() {
        suspensions += 1
        guard suspensions == 1 else { return }
        for (key, var entry) in entries {
            for handler in entry.handlers.values { handler(.release) }
            if entry.isRegistered {
                backend.unregister(id: entry.id)
                entry.status = nil
            }
            entries[key] = entry
        }
    }

    func resume() {
        guard suspensions > 0 else { return }
        suspensions -= 1
        guard suspensions == 0 else { return }
        for (key, var entry) in entries where !entry.monitorOnly {
            attemptRegistration(of: key, entry: &entry)
            entries[key] = entry
            if !entry.isRegistered {
                for refused in entry.refusalHandlers.values { refused() }
            }
        }
    }

    func deliver(id: UInt32, event: HotkeyEvent) {
        guard let key = keyByID[id], let entry = entries[key] else { return }
        for handler in entry.handlers.values { handler(event) }
    }

    private func makeEntry(for key: CarbonHotkeyKey) -> Entry {
        let id = nextID
        nextID += 1
        keyByID[id] = key
        return Entry(id: id, status: nil, handlers: [:])
    }

    private func attemptRegistration(of key: CarbonHotkeyKey, entry: inout Entry) {
        let status = backend.register(key, id: entry.id)
        entry.status = status
        health.set(key, status == noErr ? nil : .bySystem)
        if status != noErr {
            ParolaLog.notice(.dictation, "hotkey registration refused by the system: OSStatus \(Int(status)), key \(Int(key.keyCode)), modifiers \(Int(key.modifiers))")
        }
    }

    private func outcome(of entry: Entry) -> Outcome {
        if entry.monitorOnly { return .monitorOnly }
        if isSuspended { return .suspended }
        guard let status = entry.status else { return .suspended }
        return status == noErr ? .registered : .refusedByOS(status)
    }

    func outcome(for key: CarbonHotkeyKey) -> Outcome? {
        entries[key].map(outcome(of:))
    }

    #if DEBUG
    var registrationCount: Int { entries.values.filter(\.isRegistered).count }
    #endif
}

@MainActor
private final class SystemCarbonHotkeyBackend: CarbonHotkeyBackend {
    private static let signature: OSType = 0x50524C41
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlerInstalled = false

    func register(_ key: CarbonHotkeyKey, id: UInt32) -> OSStatus {
        guard installHandlerIfNeeded() else { return OSStatus(eventNotHandledErr) }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            key.keyCode, key.modifiers, EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(), 0, &ref
        )
        if status == noErr, let ref { refs[id] = ref }
        return status
    }

    func unregister(id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
    }

    private func installHandlerIfNeeded() -> Bool {
        if handlerInstalled { return true }
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            guard status == noErr, hotKeyID.signature == 0x50524C41 else { return OSStatus(eventNotHandledErr) }
            let kind: HotkeyEvent = GetEventKind(event) == UInt32(kEventHotKeyPressed) ? .press : .release
            MainActor.assumeIsolated {
                CarbonHotkeyRegistry.shared.deliver(id: hotKeyID.id, event: kind)
            }
            return noErr
        }, types.count, &types, nil, nil)
        if status != noErr {
            ParolaLog.notice(.dictation, "hotkey event handler install failed: OSStatus \(Int(status))")
            return false
        }
        handlerInstalled = true
        return true
    }
}

struct FallbackKeyEvent {
    let isDown: Bool
    let isRepeat: Bool
    let flags: NSEvent.ModifierFlags
}

@MainActor
protocol HotkeyFallbackSource: AnyObject {
    func install(keyCode: UInt16, handler: @escaping @MainActor (FallbackKeyEvent) -> Void) -> [Any]
    func remove(_ tokens: [Any])
}

@MainActor
final class NSEventFallbackSource: HotkeyFallbackSource {
    func install(keyCode: UInt16, handler: @escaping @MainActor (FallbackKeyEvent) -> Void) -> [Any] {
        let mask: NSEvent.EventTypeMask = [.keyDown, .keyUp]
        func translate(_ event: NSEvent) -> FallbackKeyEvent {
            FallbackKeyEvent(
                isDown: event.type == .keyDown,
                isRepeat: event.type == .keyDown && event.isARepeat,
                flags: event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            )
        }
        var tokens: [Any] = []
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { event in
            guard event.keyCode == keyCode else { return }
            let translated = translate(event)
            MainActor.assumeIsolated { handler(translated) }
        }) {
            tokens.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            guard event.keyCode == keyCode else { return event }
            let translated = translate(event)
            MainActor.assumeIsolated { handler(translated) }
            return event
        }) {
            tokens.append(local)
        }
        return tokens
    }

    func remove(_ tokens: [Any]) {
        for token in tokens { NSEvent.removeMonitor(token) }
    }
}

@MainActor
final class GlobalHotkeyMonitor: HotkeyMonitor {
    private let keyCode: Int
    private let modifierMask: NSEvent.ModifierFlags
    private let key: CarbonHotkeyKey
    private let registry: CarbonHotkeyRegistry
    private let keyIsDown: @Sendable (Int) -> Bool
    private var token: UUID?
    private var isPressed = false
    private var heldWatch: Task<Void, Never>?
    private let fallbackSource: any HotkeyFallbackSource
    private var fallbackTokens: [Any] = []
    private var handler: (@Sendable (HotkeyEvent) -> Void)?

    init(
        keyCode: Int = Int(kVK_F5),
        modifiers: NSEvent.ModifierFlags = [],
        registry: CarbonHotkeyRegistry = .shared,
        fallbackSource: any HotkeyFallbackSource = NSEventFallbackSource(),
        keyIsDown: @escaping @Sendable (Int) -> Bool = {
            CGEventSource.keyState(.combinedSessionState, key: CGKeyCode($0))
        }
    ) {
        self.keyCode = keyCode
        self.modifierMask = modifiers.intersection([.command, .shift, .option, .control])
        self.key = CarbonHotkeyKey(keyCode: keyCode, modifiers: modifiers)
        self.registry = registry
        self.fallbackSource = fallbackSource
        self.keyIsDown = keyIsDown
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

    private func register(handler: @escaping @Sendable (HotkeyEvent) -> Void) {
        unregister()
        self.handler = handler
        let addition = registry.add(key, onRefusalOnResume: { [weak self] in self?.installFallback() }) { [weak self] event in
            MainActor.assumeIsolated { self?.process(event) }
        }
        token = addition.token
        switch addition.outcome {
        case .refusedByOS, .monitorOnly: installFallback()
        default: break
        }
    }

    /// Key repeat and a release without a press never reach the handler.
    private func process(_ event: HotkeyEvent) {
        switch event {
        case .press:
            guard !isPressed else { return }
            isPressed = true
            watchHeldKey()
        case .release:
            guard isPressed else { return }
            isPressed = false
            heldWatch?.cancel()
            heldWatch = nil
        }
        handler?(event)
    }

    /// Carbon reports the key-up only while the modifiers still match on some systems; a poll while held backs it up.
    private func watchHeldKey() {
        heldWatch?.cancel()
        let code = keyCode
        let keyIsDown = keyIsDown
        heldWatch = Task { [weak self] in
            var missed = 0
            var seenDown = false
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                if Task.isCancelled { return }
                if keyIsDown(code) {
                    seenDown = true
                    missed = 0
                } else if seenDown {
                    missed += 1
                }
                if missed >= 2 {
                    self?.process(.release)
                    return
                }
            }
        }
    }

    private func installFallback() {
        guard fallbackTokens.isEmpty else { return }
        let required = modifierMask
        fallbackTokens = fallbackSource.install(keyCode: UInt16(keyCode)) { [weak self] event in
            guard let self else { return }
            if event.isDown {
                guard !registry.isSuspended, !event.isRepeat,
                      event.flags.intersection([.command, .control, .option, .shift]) == required else { return }
                process(.press)
            } else {
                process(.release)
            }
        }
    }

    private func unregister() {
        if let token { registry.remove(key, token: token) }
        token = nil
        fallbackSource.remove(fallbackTokens)
        fallbackTokens = []
        heldWatch?.cancel()
        heldWatch = nil
        isPressed = false
        handler = nil
    }

    #if DEBUG
    var isRegistered: Bool { registry.outcome(for: key) == .registered && token != nil }
    var hasFallback: Bool { !fallbackTokens.isEmpty }
    #endif
}

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
