import AppKit
import Foundation
import Testing
@testable import Parola
import ParolaDictation

@MainActor
@Suite("Mic hotkey controller")
struct MicHotkeyControllerTests {
    private actor GatedMonitor: HotkeyMonitor {
        private(set) var started = 0
        private(set) var stopped = 0
        private var gates: [CheckedContinuation<Void, Never>] = []

        func start(handler: @escaping @Sendable (HotkeyEvent) -> Void) async {
            started += 1
        }

        func stop() async {
            stopped += 1
            await withCheckedContinuation { gates.append($0) }
        }

        // Last-in-first-out on purpose: the newer apply resumes before the superseded
        // one, which is the interleaving that used to clobber the fresh monitor.
        func openReversed() {
            while let gate = gates.popLast() {
                gate.resume()
            }
        }
    }

    @MainActor
    private final class FakeQueue {
        var fakes: [GatedMonitor]
        init(_ fakes: [GatedMonitor]) { self.fakes = fakes }
        func next() -> GatedMonitor { fakes.removeFirst() }
    }

    private func spin(_ condition: @escaping @MainActor () async -> Bool) async -> Bool {
        for _ in 0..<5000 {
            if await condition() { return true }
            await Task.yield()
        }
        return await condition()
    }

    @Test("a superseded reconfigure never clobbers the new monitor")
    func supersededApplyKeepsNewMonitor() async {
        let fake1 = GatedMonitor()
        let fake3 = GatedMonitor()
        let queue = FakeQueue([fake1, fake3])
        let controller = MicHotkeyController()
        controller.monitorFactory = { _, _ in queue.next() }

        controller.applyConfiguration(enabled: true, keyCode: 96, modifiers: [])
        let monitorIsFake1 = await spin { (controller.monitor as? GatedMonitor) === fake1 }
        #expect(monitorIsFake1)
        let fake1Wait = await spin { await fake1.started == 1 }
        #expect(fake1Wait)

        controller.applyConfiguration(enabled: true, keyCode: 99, modifiers: [])
        let fake1Wait2 = await spin { await fake1.stopped == 1 }
        #expect(fake1Wait2)

        controller.applyConfiguration(enabled: true, keyCode: 100, modifiers: [])
        let fake1Wait3 = await spin { await fake1.stopped == 2 }
        #expect(fake1Wait3)

        await fake1.openReversed()
        let fake3Wait = await spin { await fake3.started == 1 }
        #expect(fake3Wait)

        let settled = await spin { (controller.monitor as? GatedMonitor) === fake3 }
        #expect(settled, "the cancelled apply resumed after its stop and must not touch the monitor")
    }
}
