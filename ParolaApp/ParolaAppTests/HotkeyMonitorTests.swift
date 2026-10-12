import AppKit
import Carbon.HIToolbox
import Testing
@testable import Parola
import ParolaDictation

@MainActor
private final class FakeBackend: CarbonHotkeyBackend {
    var registered: [UInt32: CarbonHotkeyKey] = [:]
    var registerCalls = 0
    var refuse = false

    func register(_ key: CarbonHotkeyKey, id: UInt32) -> Bool {
        registerCalls += 1
        guard !refuse else { return false }
        registered[id] = key
        return true
    }

    func unregister(id: UInt32) { registered[id] = nil }
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
        _ backend: FakeBackend, registry: CarbonHotkeyRegistry, code: Int = kVK_F5, mods: NSEvent.ModifierFlags = []
    ) -> GlobalHotkeyMonitor {
        GlobalHotkeyMonitor(keyCode: code, modifiers: mods, registry: registry)
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

    @Test("a refused registration leaves the monitor unregistered")
    func refusedRegistration() async {
        let backend = FakeBackend()
        backend.refuse = true
        let registry = CarbonHotkeyRegistry(backend: backend)
        let monitor = makeMonitor(backend, registry: registry)
        await monitor.start { _ in }
        #expect(!monitor.isRegistered)
        #expect(registry.registrationCount == 0)
    }

    @Test("suspending releases the OS registrations and resuming restores them")
    func suspendWhileRecording() async {
        let backend = FakeBackend()
        let registry = CarbonHotkeyRegistry(backend: backend)
        let monitor = makeMonitor(backend, registry: registry)
        let log = EventLog()
        await monitor.start { log.append($0) }
        registry.setSuspended(true)
        #expect(backend.registered.isEmpty)
        registry.setSuspended(false)
        #expect(backend.registered.count == 1)
        registry.deliver(id: backend.registered.keys.first!, event: .press)
        #expect(log.all == [.press])
    }

    @Test("a monitor started while suspended registers on resume")
    func startWhileSuspended() async {
        let backend = FakeBackend()
        let registry = CarbonHotkeyRegistry(backend: backend)
        registry.setSuspended(true)
        let monitor = makeMonitor(backend, registry: registry)
        await monitor.start { _ in }
        #expect(backend.registered.isEmpty)
        registry.setSuspended(false)
        #expect(backend.registered.count == 1)
    }
}
