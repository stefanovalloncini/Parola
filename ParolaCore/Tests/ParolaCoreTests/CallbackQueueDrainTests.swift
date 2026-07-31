import Foundation
import Testing
@testable import ParolaCore

@Suite("Callback queue drain")
struct CallbackQueueDrainTests {
    @Test("drain returns only after work already on the queue has finished")
    func waitsForInFlightWork() async {
        let queue = DispatchQueue(label: "test.callback-drain")
        let finished = Flag()
        queue.async {
            Thread.sleep(forTimeInterval: 0.05)
            finished.raise()
        }

        await queue.drain()

        #expect(finished.isRaised)
    }

    @Test("draining an idle queue returns")
    func idleQueue() async {
        let queue = DispatchQueue(label: "test.callback-drain-idle")
        await queue.drain()
    }

    @Test("many drains from the cooperative pool all return")
    func concurrentDrains() async {
        let queues = (0..<32).map { DispatchQueue(label: "test.callback-drain-\($0)") }
        for queue in queues {
            queue.async { Thread.sleep(forTimeInterval: 0.02) }
        }

        await withTaskGroup(of: Void.self) { group in
            for queue in queues {
                group.addTask { await queue.drain() }
            }
        }
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func raise() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var isRaised: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
