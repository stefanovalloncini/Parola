import AppKit
import Carbon.HIToolbox
import Testing
@testable import Parola
import ParolaDictation

@MainActor
private final class FakeBackend: CarbonHotkeyBackend {
    var registered: [UInt32: CarbonHotkeyKey] = [:]
    var registerCalls = 0
    var refuseWith: OSStatus?

    func register(_ key: CarbonHotkeyKey, id: UInt32) -> OSStatus {
        registerCalls += 1
        if let refuseWith { return refuseWith }
        registered[id] = key
        return noErr
    }

    func unregister(id: UInt32) { registered[id] = nil }
}

@MainActor
final class FakeFallback: HotkeyFallbackSource {
    var installs: [UInt16] = []
    var removals = 0
    var handlers: [@MainActor (FallbackKeyEvent) -> Void] = []

    func install(keyCode: UInt16, handler: @escaping @MainActor (FallbackKeyEvent) -> Void) -> [Any] {
        installs.append(keyCode)
        handlers.append(handler)
        return [1]
    }

    func remove(_ tokens: [Any]) {
        removals += tokens.count
        handlers = []
    }

    func send(down: Bool, flags: NSEvent.ModifierFlags, isRepeat: Bool = false) {
        for handler in handlers { handler(FallbackKeyEvent(isDown: down, isRepeat: isRepeat, flags: flags)) }
    }
}

private final class HeldKey: @unchecked Sendable {
    private let lock = NSLock()
    private var down = true
    var isDown: Bool { lock.withLock { down } }
    func lift() { lock.withLock { down = false } }
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [HotkeyEvent] = []
    func append(_ event: HotkeyEvent) { lock.withLock { items.append(event) } }
    var all: [HotkeyEvent] { lock.withLock { items } }
}

@MainActor
@Suite("Carbon hotkeys")
struct HotkeyMonitorTests {
    private func makeMonitor(
        _ backend: FakeBackend, registry: CarbonHotkeyRegistry, code: Int = kVK_F5, mods: NSEvent.ModifierFlags = [],
        fallback: FakeFallback = FakeFallback()
    ) -> GlobalHotkeyMonitor {
        GlobalHotkeyMonitor(keyCode: code, modifiers: mods, registry: registry, fallbackSource: fallback)
    }

    @Test("only the four Carbon modifiers survive; function, numpad and caps lock are dropped")
    func modifierMapping() {
        let key = CarbonHotkeyKey(
            keyCode: kVK_F5, modifiers: [.command, .option, .function, .numericPad, .capsLock]
        )
        #expect(key.modifiers == UInt32(cmdKey | optionKey))
        #expect(CarbonHotkeyKey(keyCode: 15, modifiers: [.control, .shift]).modifiers == UInt32(controlKey | shiftKey))
    }

    @Test("nothing is registered until a monitor starts, and stop releases it")
    func registersOnStartOnly() async {
        let backend = FakeBackend()
        let registry = CarbonHotkeyRegistry(backend: backend)
        let monitor = makeMonitor(backend, registry: registry)
        #expect(backend.registered.isEmpty)
        await monitor.start { _ in }
        #expect(backend.registered.count == 1)
        #expect(backend.registered.values.first == CarbonHotkeyKey(keyCode: kVK_F5, modifiers: []))
        await monitor.stop()
        #expect(backend.registered.isEmpty)
    }

    @Test("press and release reach the handler once; key repeat and a stray release do not")
    func pressHoldRelease() async {
        let backend = FakeBackend()
        let registry = CarbonHotkeyRegistry(backend: backend)
        let monitor = makeMonitor(backend, registry: registry)
        let log = EventLog()
        await monitor.start { log.append($0) }
        let id = backend.registered.keys.first!
        registry.deliver(id: id, event: .release)
        registry.deliver(id: id, event: .press)
        registry.deliver(id: id, event: .press)
        registry.deliver(id: id, event: .release)
        registry.deliver(id: id, event: .release)
        #expect(log.all == [.press, .release])
    }

    @Test("two monitors on one combination share a single registration and both hear it")
    func sharedRegistration() async {
        let backend = FakeBackend()
        let registry = CarbonHotkeyRegistry(backend: backend)
        let first = makeMonitor(backend, registry: registry, code: 15, mods: [.control, .option, .command])
        let second = makeMonitor(backend, registry: registry, code: 15, mods: [.control, .option, .command])
        let log1 = EventLog()
        let log2 = EventLog()
        await first.start { log1.append($0) }
        await second.start { log2.append($0) }
        #expect(backend.registered.count == 1)
        registry.deliver(id: backend.registered.keys.first!, event: .press)
        #expect(log1.all == [.press] && log2.all == [.press])
        await first.stop()
        #expect(backend.registered.count == 1)
        await second.stop()
        #expect(backend.registered.isEmpty)
    }

    @Test("restarting a monitor replaces its registration")
    func restartDoesNotLeak() async {
        let backend = FakeBackend()
        let registry = CarbonHotkeyRegistry(backend: backend)
        let monitor = makeMonitor(backend, registry: registry)
        await monitor.start { _ in }
        await monitor.start { _ in }
        #expect(backend.registered.count == 1)
        #expect(registry.registrationCount == 1)
    }

    @Test("a combination the system refuses is reported, logged and served by the fallback")
    func refusedByTheSystem() async {
        let backend = FakeBackend()
        backend.refuseWith = -9878
        let registry = CarbonHotkeyRegistry(backend: backend)
        let fallback = FakeFallback()
        let monitor = makeMonitor(backend, registry: registry, code: kVK_ANSI_D, mods: [.control], fallback: fallback)
        let log = EventLog()
        await monitor.start { log.append($0) }
        #expect(!monitor.isRegistered)
        #expect(fallback.installs == [UInt16(kVK_ANSI_D)])
        #expect(registry.health.isRefused(keyCode: kVK_ANSI_D, modifiers: [.control]))
        fallback.send(down: true, flags: [.control])
        fallback.send(down: true, flags: [.control], isRepeat: true)
        fallback.send(down: false, flags: [])
        #expect(log.all == [.press, .release])
        await monitor.stop()
        #expect(fallback.removals == 1)
        #expect(!registry.health.isRefused(keyCode: kVK_ANSI_D, modifiers: [.control]))
    }

    @Test("an option-only combination is never handed to Carbon and is served by the fallback")
    func optionOnlyUsesFallback() async {
        for mods: NSEvent.ModifierFlags in [[.option], [.option, .shift]] {
            let backend = FakeBackend()
            let registry = CarbonHotkeyRegistry(backend: backend)
            let fallback = FakeFallback()
            let monitor = makeMonitor(backend, registry: registry, code: kVK_Space, mods: mods, fallback: fallback)
            let log = EventLog()
            await monitor.start { log.append($0) }
            #expect(backend.registerCalls == 0)
            #expect(fallback.installs == [UInt16(kVK_Space)])
            #expect(registry.health.isRefused(keyCode: kVK_Space, modifiers: mods))
            fallback.send(down: true, flags: mods)
            fallback.send(down: false, flags: [])
            #expect(log.all == [.press, .release])
            await monitor.stop()
            #expect(!registry.health.isRefused(keyCode: kVK_Space, modifiers: mods))
        }
    }

    @Test("a combination with ⌘ or ⌃ is not option-only")
    func optionWithCommandStaysOnCarbon() async {
        let backend = FakeBackend()
        let registry = CarbonHotkeyRegistry(backend: backend)
        let fallback = FakeFallback()
        let monitor = makeMonitor(backend, registry: registry, code: kVK_Space, mods: [.option, .control], fallback: fallback)
        await monitor.start { _ in }
        #expect(backend.registerCalls == 1)
        #expect(fallback.installs.isEmpty)
    }

    @Test("a saved bare letter is refused by policy and never registered")
    func policyRefusesBareKeys() async {
        let backend = FakeBackend()
        let registry = CarbonHotkeyRegistry(backend: backend)
        let monitor = makeMonitor(backend, registry: registry, code: kVK_Escape, mods: [])
        await monitor.start { _ in }
        #expect(backend.registerCalls == 0)
        #expect(!monitor.hasFallback)
        #expect(registry.health.isRefused(keyCode: kVK_Escape, modifiers: []))
    }

    @Test("adding to an entry that failed earlier tries the system again")
    func retryOnAdd() async {
        let backend = FakeBackend()
        backend.refuseWith = -9878
        let registry = CarbonHotkeyRegistry(backend: backend)
        let key = CarbonHotkeyKey(keyCode: kVK_F5, modifiers: [])
        #expect(registry.add(key) { _ in }.outcome == .refusedByOS(-9878))
        backend.refuseWith = nil
        #expect(registry.add(key) { _ in }.outcome == .registered)
        #expect(backend.registered.count == 1)
        #expect(!registry.health.isRefused(keyCode: kVK_F5, modifiers: []))
    }

    @Test("suspensions count: the key stays released until the last recorder finishes")
    func suspendCounts() async {
        let backend = FakeBackend()
        let registry = CarbonHotkeyRegistry(backend: backend)
        let monitor = makeMonitor(backend, registry: registry)
        await monitor.start { _ in }
        registry.suspend()
        registry.suspend()
        #expect(backend.registered.isEmpty)
        registry.resume()
        #expect(backend.registered.isEmpty)
        registry.resume()
        #expect(backend.registered.count == 1)
        registry.resume()
        #expect(backend.registered.count == 1)
    }

    @Test("suspending while the key is held releases it")
    func suspendReleasesHeldKey() async {
        let backend = FakeBackend()
        let registry = CarbonHotkeyRegistry(backend: backend)
        let monitor = makeMonitor(backend, registry: registry)
        let log = EventLog()
        await monitor.start { log.append($0) }
        registry.deliver(id: backend.registered.keys.first!, event: .press)
        registry.suspend()
        #expect(log.all == [.press, .release])
        registry.resume()
        registry.deliver(id: backend.registered.keys.first!, event: .press)
        #expect(log.all == [.press, .release, .press])
    }

    @Test("a monitor started while suspended registers on resume")
    func startWhileSuspended() async {
        let backend = FakeBackend()
        let registry = CarbonHotkeyRegistry(backend: backend)
        registry.suspend()
        let monitor = makeMonitor(backend, registry: registry)
        await monitor.start { _ in }
        #expect(backend.registered.isEmpty)
        registry.resume()
        #expect(backend.registered.count == 1)
        #expect(monitor.isRegistered)
    }

    @Test("the release arrives even when the system never reports the key-up")
    func heldKeyPollReleases() async {
        let backend = FakeBackend()
        let registry = CarbonHotkeyRegistry(backend: backend)
        let held = HeldKey()
        let monitor = GlobalHotkeyMonitor(
            keyCode: 2, modifiers: [.control, .option], registry: registry, keyIsDown: { _ in held.isDown }
        )
        let log = EventLog()
        await monitor.start { log.append($0) }
        registry.deliver(id: backend.registered.keys.first!, event: .press)
        held.lift()
        await waitUntil { log.all == [.press, .release] }
        registry.deliver(id: backend.registered.keys.first!, event: .release)
        #expect(log.all == [.press, .release])
    }

    @Test("rules: bare keys, option-only and reserved command keys are rejected; F keys and ⌃/⌘ combos pass")
    func recorderRules() {
        #expect(HotkeyRules.rejection(keyCode: kVK_Space, modifiers: [.option]) == .optionOnly)
        #expect(HotkeyRules.rejection(keyCode: kVK_Space, modifiers: [.option, .shift]) == .optionOnly)
        #expect(HotkeyRules.rejection(keyCode: kVK_ANSI_D, modifiers: []) == .needsCommandOrControl)
        #expect(HotkeyRules.rejection(keyCode: kVK_Escape, modifiers: [.shift]) == .needsCommandOrControl)
        for code in [kVK_ANSI_W, kVK_ANSI_Q, kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_X, kVK_ANSI_Z, kVK_ANSI_A, kVK_Space, kVK_Tab] {
            #expect(HotkeyRules.rejection(keyCode: code, modifiers: [.command]) == .reserved)
        }
        #expect(HotkeyRules.rejection(keyCode: kVK_F5, modifiers: []) == nil)
        #expect(HotkeyRules.rejection(keyCode: kVK_F20, modifiers: [.option]) == nil)
        #expect(HotkeyRules.rejection(keyCode: kVK_ANSI_D, modifiers: [.control, .option]) == nil)
        #expect(HotkeyRules.rejection(keyCode: kVK_ANSI_R, modifiers: [.command, .option, .control]) == nil)
        #expect(HotkeyRules.rejection(keyCode: kVK_ANSI_W, modifiers: [.command, .option]) == nil)
    }
}
