import Foundation
import Testing
import WhisperKit
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

@Suite("Streaming decode slot wiring")
struct StreamingDecodeSlotWiringTests {
    private static let tiny = "openai_whisper-tiny"

    private func overlap(slot: StreamingDecodeSlot?) async throws -> Int {
        let probe = CacheProbe()
        let cache = StreamingModelCache.probing(probe)
        let store = ModelStore(modelsDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("slot-wiring-\(UUID().uuidString)"))
        try store.seedInstalledModel(Self.tiny)
        let lease = try await cache.borrow(Self.tiny, store: store)
        let gate = UninterruptibleGate()
        let active = Awaitable(0)
        let peak = Awaitable(0)
        let decoder = StreamingRealtimeLoop.Decoder(options: DecodingOptions()) { _, _, _ in
            active.update { $0 += 1 }
            peak.update { $0 = max($0, active.value) }
            await gate.wait()
            active.update { $0 -= 1 }
            return TranscriptionResult(text: "", segments: [], language: "en", timings: TranscriptionTimings())
        }
        func session() -> StreamingTranscriptionSession {
            StreamingTranscriptionSession(
                modelStore: store, modelCache: cache, decodeSlot: slot, makeDecoder: { _, _ in decoder }
            )
        }
        let first = try await session().decoder(holding: lease, options: TranscriptionOptions())
        let second = try await session().decoder(holding: lease, options: TranscriptionOptions())
        let one = Task { try await first.transcribe([], DecodingOptions(), { _ in nil }) }
        let two = Task { try await second.transcribe([], DecodingOptions(), { _ in nil }) }
        await gate.arrivals.wait(atLeast: 1, "a decode to start")
        if slot == nil { await gate.arrivals.wait(atLeast: 2, "both decodes to start") }
        gate.open()
        _ = try await one.value
        _ = try await two.value
        await lease.release()
        return peak.value
    }

    @Test("dictation sessions sharing a slot never decode at once", .timeLimit(.minutes(1)))
    func slotSerialises() async throws {
        #expect(try await overlap(slot: StreamingDecodeSlot()) == 1)
    }

    @Test("sessions without a slot decode side by side", .timeLimit(.minutes(1)))
    func noSlotNoLimit() async throws {
        #expect(try await overlap(slot: nil) == 2)
    }
}
