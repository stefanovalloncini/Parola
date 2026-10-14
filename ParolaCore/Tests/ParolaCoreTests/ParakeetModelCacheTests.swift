import CoreML
import Foundation
import Testing
@preconcurrency import FluidAudio
@testable import ParolaCore

private func fakeModels() -> AsrModels {
    AsrModels(
        encoder: nil, preprocessor: MLModel(), decoder: MLModel(), joint: MLModel(),
        configuration: MLModelConfiguration(), vocabulary: [:], version: .v2
    )
}

@Suite("Streaming cache with a Parakeet entry")
struct ParakeetModelCacheTests {
    private static let v2 = "nvidia_parakeet-tdt-0.6b-v2"
    private static let tiny = "openai_whisper-tiny"

    private static func makeStore() -> ModelStore {
        ModelStore(modelsDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("parakeet-cache-tests-\(UUID().uuidString)"))
    }

    private static func cache(loads: Awaitable<Int>, clock: TestClock = TestClock()) -> StreamingModelCache {
        StreamingModelCache(
            loader: { _, _ in try await StreamingModelCache.makeUnloadedKit() },
            parakeetLoader: { _, _ in
                loads.increment()
                return fakeModels()
            },
            clock: clock
        )
    }

    @Test("a borrow loads the Parakeet models once and shares them")
    func borrowSharesOneLoad() async throws {
        let loads = Awaitable(0)
        let cache = Self.cache(loads: loads)
        let store = Self.makeStore()

        let first = try await cache.borrow(Self.v2, store: store)
        let second = try await cache.borrow(Self.v2, store: store)

        guard case .parakeet = first.payload, case .parakeet = second.payload else {
            Issue.record("expected Parakeet payloads")
            return
        }
        #expect(loads.value == 1)
        #expect(await cache.leaseCount(for: Self.v2) == 2)
        await first.release()
        await second.release()
    }

    @Test("a warm loads without a lease, and the entry idles out and loads again on the next borrow")
    func warmThenIdleUnload() async throws {
        let loads = Awaitable(0)
        let clock = TestClock()
        let cache = Self.cache(loads: loads, clock: clock)
        let store = Self.makeStore()

        await cache.warm(Self.v2, store: store)
        #expect(await cache.residentModelNames() == [Self.v2])
        #expect(await cache.leaseCount(for: Self.v2) == 0)

        await clock.waitForSleeper()
        clock.advance(by: ModelResidency.idleTimeout)
        let idled = await eventually { await cache.residentModelNames().isEmpty }
        #expect(idled)

        let lease = try await cache.borrow(Self.v2, store: store)
        #expect(loads.value == 2)
        await lease.release()
    }

    @Test("memory pressure keeps a leased Parakeet entry and drops it when the lease returns")
    func unloadUnleasedWaitsForTheLease() async throws {
        let loads = Awaitable(0)
        let cache = Self.cache(loads: loads)
        let store = Self.makeStore()
        let lease = try await cache.borrow(Self.v2, store: store)

        #expect(await cache.unloadUnleased().isEmpty)
        #expect(await cache.residentModelNames() == [Self.v2])

        await lease.release()
        let dropped = await eventually { await cache.residentModelNames().isEmpty }
        #expect(dropped)
    }

    @Test("evicting drops the entry at once when no lease holds it")
    func evictDropsTheEntry() async throws {
        let loads = Awaitable(0)
        let cache = Self.cache(loads: loads)
        let store = Self.makeStore()
        await cache.warm(Self.v2, store: store)

        await cache.evict(Self.v2)

        #expect(await cache.residentModelNames().isEmpty)
    }

    @Test("borrowing a Whisper model drops the Parakeet one")
    func switchingEnginesEvicts() async throws {
        let loads = Awaitable(0)
        let cache = Self.cache(loads: loads)
        let store = Self.makeStore()
        await cache.warm(Self.v2, store: store)

        let lease = try await cache.borrow(Self.tiny, store: store)

        #expect(await cache.residentModelNames() == [Self.tiny])
        await lease.release()
    }
}

private func eventually(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(30)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return await condition()
}
