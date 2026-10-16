import Foundation
import Testing
@testable import ParolaCore

@Suite("Streaming decode slot")
struct StreamingDecodeSlotTests {
    @Test("a second decode waits for the first and then runs", .timeLimit(.minutes(1)))
    func decodesRunOneAtATime() async throws {
        let slot = StreamingDecodeSlot()
        let gate = UninterruptibleGate()
        let running = Awaitable(0)
        let order = OrderLog()

        let first = Task {
            try await slot.run {
                running.increment()
                await gate.wait()
                await order.add("first")
            }
        }
        await running.wait(atLeast: 1, "the first decode to start")
        let second = Task {
            try await slot.run {
                running.increment()
                await order.add("second")
            }
        }
        await gate.arrivals.wait(atLeast: 1, "the first decode to hold the slot")
        #expect(running.value == 1)

        gate.open()
        try await first.value
        try await second.value
        #expect(await order.items == ["first", "second"])
    }

    @Test("a decode cancelled while it waits never runs", .timeLimit(.minutes(1)))
    func cancelledWaiterNeverRuns() async throws {
        let slot = StreamingDecodeSlot()
        let gate = UninterruptibleGate()
        let ran = OrderLog()
        let first = Task { try await slot.run { await gate.wait() } }
        await gate.arrivals.wait(atLeast: 1, "the first decode to hold the slot")
        let second = Task { try await slot.run { await ran.add("second") } }

        second.cancel()
        await #expect(throws: CancellationError.self) { try await second.value }

        gate.open()
        try await first.value
        #expect(await ran.items.isEmpty)
    }
}

private actor OrderLog {
    private(set) var items: [String] = []
    func add(_ item: String) { items.append(item) }
}
