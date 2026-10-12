import Foundation
import Testing
@preconcurrency import WhisperKit
@testable import ParolaCore

/// What a test cache did to its kits: fresh loads, reloads of a kept kit, and unloads.
final class CacheProbe: Sendable {
    let loads = Awaitable(0)
    let reloads = Awaitable(0)
    let unloads = Awaitable(0)
}

actor LoadGate {
    private var waiters: [String: CheckedContinuation<Void, Never>] = [:]
    private var opened: Set<String> = []

    func wait(_ name: String) async {
        if opened.contains(name) { return }
        await withCheckedContinuation { waiters[name] = $0 }
    }

    func open(_ name: String) {
        opened.insert(name)
        waiters.removeValue(forKey: name)?.resume()
    }
}

extension StreamingModelCache {
    static func makeUnloadedKit() async throws -> SharedWhisperKit {
        let kit = try await WhisperKit(WhisperKitConfig(
            model: "tiny",
            verbose: false,
            logLevel: .none,
            prewarm: false,
            load: false,
            download: false
        ))
        return SharedWhisperKit(kit: kit)
    }

    static func probing(
        _ probe: CacheProbe,
        clock: TestClock = TestClock(),
        gate: LoadGate? = nil
    ) -> StreamingModelCache {
        StreamingModelCache(
            loader: { name, _ in
                probe.loads.increment()
                await gate?.wait(name)
                return try await makeUnloadedKit()
            },
            reloader: { _ in probe.reloads.increment() },
            unloader: { _ in probe.unloads.increment() },
            clock: clock
        )
    }
}

@Suite("Streaming model cache")
struct StreamingModelCacheTests {
    private static let tiny = "openai_whisper-tiny"

    private static func makeStore() -> ModelStore {
        ModelStore(modelsDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("streaming-cache-tests-\(UUID().uuidString)"))
    }

    @Test("concurrent borrows of the same model share one load")
    func concurrentBorrowsSingleFlight() async throws {
        let probe = CacheProbe()
        let cache = StreamingModelCache.probing(probe)
        let store = Self.makeStore()

        let identities = try await withThrowingTaskGroup(of: ObjectIdentifier.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    ObjectIdentifier(try await cache.borrow(Self.tiny, store: store).shared.kit)
                }
            }
            return try await group.reduce(into: [ObjectIdentifier]()) { $0.append($1) }
        }

        #expect(Set(identities).count == 1)
        #expect(probe.loads.value == 1)
    }

    @Test("sequential borrows reuse the loaded instance")
    func sequentialBorrowsReuse() async throws {
        let probe = CacheProbe()
        let cache = StreamingModelCache.probing(probe)
        let store = Self.makeStore()

        let first = try await cache.borrow(Self.tiny, store: store)
        let second = try await cache.borrow(Self.tiny, store: store)

        #expect(first.shared.kit === second.shared.kit)
        #expect(probe.loads.value == 1)
        #expect(await cache.leaseCount(for: Self.tiny) == 2)
    }

    @Test("different models load independently")
    func differentModelsLoadSeparately() async throws {
        let probe = CacheProbe()
        let cache = StreamingModelCache.probing(probe)
        let store = Self.makeStore()

        let tiny = try await cache.borrow(Self.tiny, store: store)
        let base = try await cache.borrow("openai_whisper-base", store: store)

        #expect(tiny.shared.kit !== base.shared.kit)
        #expect(probe.loads.value == 2)
    }

    @Test("unloadAll evicts and the next borrow reloads")
    func unloadAllEvictsAndReloads() async throws {
        let probe = CacheProbe()
        let cache = StreamingModelCache.probing(probe)
        let store = Self.makeStore()

        let first = try await cache.borrow(Self.tiny, store: store)
        await cache.unloadAll()
        let second = try await cache.borrow(Self.tiny, store: store)

        #expect(first.shared.kit !== second.shared.kit)
        #expect(probe.loads.value == 2)
    }

    @Test("a failed load is not cached, the next borrow retries, and the failed borrow holds no lease")
    func failedLoadRetries() async throws {
        struct LoadFailure: Error {}
        let loads = Awaitable(0)
        let cache = StreamingModelCache { _, _ in
            loads.increment()
            if loads.value == 1 { throw LoadFailure() }
            return try await StreamingModelCache.makeUnloadedKit()
        }
        let store = Self.makeStore()

        await #expect(throws: LoadFailure.self) {
            _ = try await cache.borrow(Self.tiny, store: store)
        }
        #expect(await cache.leaseCount(for: Self.tiny) == 0)
        _ = try await cache.borrow(Self.tiny, store: store)

        #expect(loads.value == 2)
    }

    @Test("a load superseded by a switch to another model is not cached")
    func supersededLoadNotCached() async throws {
        let probe = CacheProbe()
        let gate = LoadGate()
        let cache = StreamingModelCache.probing(probe, gate: gate)
        let store = Self.makeStore()

        let tiny = GuardedTask { try await cache.borrow(Self.tiny, store: store) }
        await probe.loads.wait(atLeast: 1, "the tiny load to start")
        let small = GuardedTask { try await cache.borrow("openai_whisper-small", store: store) }
        await probe.loads.wait(atLeast: 2, "the small load to start")

        // The superseded tiny load lands after small was requested; only small may stay cached.
        await gate.open(Self.tiny)
        _ = try await tiny.value("the superseded tiny borrow")
        await gate.open("openai_whisper-small")
        _ = try await small.value("the small borrow")

        _ = try await cache.borrow("openai_whisper-small", store: store)
        #expect(probe.loads.value == 2, "the latest borrow stays cached")

        _ = try await cache.borrow(Self.tiny, store: store)
        #expect(probe.loads.value == 3, "the superseded load must not have been cached")
    }

    @Test("a cancelled borrow returns promptly, its finished load stays cached, then idles out")
    func cancelledBorrowKeepsLoadWarmThenIdlesOut() async throws {
        let probe = CacheProbe()
        let clock = TestClock()
        let gate = LoadGate()
        let cache = StreamingModelCache.probing(probe, clock: clock, gate: gate)
        let store = Self.makeStore()

        let borrower = Task { try await cache.borrow(Self.tiny, store: store) }
        await probe.loads.wait(atLeast: 1, "the load to start")
        borrower.cancel()
        // The gate is still closed here: if this wait weren't cancellation-responsive,
        // awaiting the borrower would hang on the in-flight load.
        await #expect(throws: CancellationError.self) { _ = try await borrower.value }
        #expect(await cache.leaseCount(for: Self.tiny) == 0, "the cancelled borrow gave its reservation back")

        await gate.open(Self.tiny)
        await clock.waitForSleeper()
        #expect(await cache.residentModelNames() == [Self.tiny], "the load survived the cancelled borrower")

        clock.advance(by: ModelResidency.idleTimeout)
        await probe.unloads.wait(atLeast: 1, "the unborrowed load to idle out")
        #expect(await cache.residentModelNames().isEmpty)
        #expect(probe.loads.value == 1)
    }

    @Test("borrowing a different model evicts the previous one")
    func borrowEvictsOtherModels() async throws {
        let probe = CacheProbe()
        let cache = StreamingModelCache.probing(probe)
        let store = Self.makeStore()

        _ = try await cache.borrow(Self.tiny, store: store)
        _ = try await cache.borrow(Self.tiny, store: store)
        #expect(probe.loads.value == 1)

        _ = try await cache.borrow("openai_whisper-small", store: store)
        #expect(probe.loads.value == 2)

        _ = try await cache.borrow(Self.tiny, store: store)
        #expect(probe.loads.value == 3, "switching back reloads: the switch away must have freed the old instance")
    }

    @Test("a model with no lease unloads after the idle timeout")
    func unleasedModelUnloadsAfterIdle() async throws {
        let probe = CacheProbe()
        let clock = TestClock()
        let cache = StreamingModelCache.probing(probe, clock: clock)
        let store = Self.makeStore()

        let lease = try await cache.borrow(Self.tiny, store: store)
        await lease.release()
        await clock.waitForSleeper()
        clock.advance(by: ModelResidency.idleTimeout - .seconds(1))
        #expect(await cache.residentModelNames() == [Self.tiny], "a second short of the timeout")

        clock.advance(by: .seconds(1))
        await probe.unloads.wait(atLeast: 1, "the idle unload")
        #expect(await cache.residentModelNames().isEmpty)

        _ = try await cache.borrow(Self.tiny, store: store)
        #expect(probe.reloads.value == 1, "the next borrow brings the models back")
        #expect(await cache.residentModelNames() == [Self.tiny])
    }

    @Test("an idle unload keeps the kit and reloads its models on the next borrow")
    func idleUnloadKeepsTheKit() async throws {
        let probe = CacheProbe()
        let clock = TestClock()
        let cache = StreamingModelCache.probing(probe, clock: clock)
        let store = Self.makeStore()

        let first = try await cache.borrow(Self.tiny, store: store)
        let kit = first.shared.kit
        await first.release()
        await clock.waitForSleeper()
        clock.advance(by: ModelResidency.idleTimeout)
        await probe.unloads.wait(atLeast: 1, "the idle unload")

        let second = try await cache.borrow(Self.tiny, store: store)
        #expect(second.shared.kit === kit)
        #expect(probe.loads.value == 1)
        #expect(probe.reloads.value == 1)
    }

    @Test("a live lease keeps the model past the timeout")
    func liveLeaseKeepsTheModel() async throws {
        let probe = CacheProbe()
        let clock = TestClock()
        let cache = StreamingModelCache.probing(probe, clock: clock)
        let store = Self.makeStore()

        let held = try await cache.borrow(Self.tiny, store: store)
        let brief = try await cache.borrow(Self.tiny, store: store)
        await brief.release()
        await cache.warm(Self.tiny, store: store)
        #expect(clock.sleeperCount == 0, "no unload is armed while a lease is out")

        clock.advance(by: ModelResidency.idleTimeout)
        clock.advance(by: ModelResidency.idleTimeout)
        #expect(await cache.residentModelNames() == [Self.tiny])
        #expect(probe.loads.value == 1)
        #expect(probe.unloads.value == 0)

        await held.release()
        await clock.waitForSleeper()
        clock.advance(by: ModelResidency.idleTimeout)
        await probe.unloads.wait(atLeast: 1, "the unload once the last lease is back")
    }

    @Test("a borrow inside the idle window cancels the unload")
    func borrowInsideTheWindowCancelsTheUnload() async throws {
        let probe = CacheProbe()
        let clock = TestClock()
        let cache = StreamingModelCache.probing(probe, clock: clock)
        let store = Self.makeStore()

        let first = try await cache.borrow(Self.tiny, store: store)
        await first.release()
        await clock.waitForSleeper()
        clock.advance(by: .seconds(300))

        let second = try await cache.borrow(Self.tiny, store: store)
        #expect(clock.sleeperCount == 0, "the borrow disarmed the pending unload")
        clock.advance(by: ModelResidency.idleTimeout)
        #expect(await cache.residentModelNames() == [Self.tiny])
        #expect(probe.unloads.value == 0)

        await second.release()
        await clock.waitForSleeper()
        clock.advance(by: ModelResidency.idleTimeout)
        await probe.unloads.wait(atLeast: 1, "the unload a full timeout after the last release")
    }

    @Test("a warm with no borrower idles out")
    func warmWithoutBorrowerIdlesOut() async throws {
        let probe = CacheProbe()
        let clock = TestClock()
        let cache = StreamingModelCache.probing(probe, clock: clock)
        let store = Self.makeStore()

        await cache.warm(Self.tiny, store: store)
        #expect(await cache.residentModelNames() == [Self.tiny])
        #expect(await cache.leaseCount(for: Self.tiny) == 0)

        await clock.waitForSleeper()
        clock.advance(by: ModelResidency.idleTimeout)
        await probe.unloads.wait(atLeast: 1, "the warmed model to idle out")
        #expect(await cache.residentModelNames().isEmpty)
    }

    @Test("pressure and evict leave a leased model alone and drop an unleased one")
    func pressureAndEvictSpareLeasedModels() async throws {
        let probe = CacheProbe()
        let cache = StreamingModelCache.probing(probe)
        let store = Self.makeStore()

        let lease = try await cache.borrow(Self.tiny, store: store)
        #expect(await cache.unloadUnleased().isEmpty)
        await cache.evict(Self.tiny)
        #expect(await cache.residentModelNames() == [Self.tiny])
        #expect(probe.unloads.value == 0)

        await lease.release()
        await probe.unloads.wait(atLeast: 1, "the pressure unload the lease was holding up")
        #expect(await cache.residentModelNames().isEmpty)

        let again = try await cache.borrow(Self.tiny, store: store)
        #expect(probe.reloads.value == 1, "pressure kept the kit for a cheap reload")
        await again.release()
        await cache.evict(Self.tiny)
        #expect(await cache.residentModelNames().isEmpty)

        _ = try await cache.borrow(Self.tiny, store: store)
        #expect(probe.loads.value == 2, "an evicted model is loaded fresh")
    }

    @Test("a lease is reserved before the load finishes, so evict during the load doesn't drop it")
    func leaseReservedBeforeTheLoadFinishes() async throws {
        let probe = CacheProbe()
        let gate = LoadGate()
        let cache = StreamingModelCache.probing(probe, gate: gate)
        let store = Self.makeStore()

        let borrower = GuardedTask { try await cache.borrow(Self.tiny, store: store) }
        await probe.loads.wait(atLeast: 1, "the load to start")
        #expect(await cache.leaseCount(for: Self.tiny) == 1)
        await cache.evict(Self.tiny)
        await cache.unloadUnleased()

        await gate.open(Self.tiny)
        let lease = try #require(try await borrower.value("the borrow to finish"))
        #expect(await cache.residentModelNames() == [Self.tiny])
        _ = try await cache.borrow(Self.tiny, store: store)
        #expect(probe.loads.value == 1, "the borrowed load stayed cached")
        await lease.release()
    }

    @Test("an evict that waits for the release drops an unleased model at once and a leased one when its last lease comes back")
    func evictWhenReleasedWaitsForTheLastLease() async throws {
        let probe = CacheProbe()
        let cache = StreamingModelCache.probing(probe)
        let store = Self.makeStore()

        await cache.warm(Self.tiny, store: store)
        await cache.evictWhenReleased(Self.tiny)
        let afterUnleasedEvict = await cache.residentModelNames()
        #expect(afterUnleasedEvict.isEmpty)

        let first = try await cache.borrow(Self.tiny, store: store)
        let second = try await cache.borrow(Self.tiny, store: store)
        await cache.evictWhenReleased(Self.tiny)
        await first.release()
        let whileOneLeaseIsOut = await cache.residentModelNames()
        #expect(whileOneLeaseIsOut == [Self.tiny], "a session still decoding keeps the model")

        await second.release()
        let afterTheLastLease = await cache.residentModelNames()
        #expect(afterTheLastLease.isEmpty)
        #expect(probe.unloads.value == 0, "the kit is dropped, not unloaded for a cheap reload")

        let again = try await cache.borrow(Self.tiny, store: store)
        #expect(probe.loads.value == 3, "each evict made the next borrow load fresh")
        await again.release()
        let afterARelease = await cache.residentModelNames()
        #expect(afterARelease == [Self.tiny], "the evict was spent on the lease it waited for")
    }

    @Test("a shorter idle timeout applies to a model already waiting out the longer one")
    func shorterIdleTimeoutRearmsThePendingUnload() async throws {
        let probe = CacheProbe()
        let clock = TestClock()
        let cache = StreamingModelCache.probing(probe, clock: clock)
        let store = Self.makeStore()

        await cache.warm(Self.tiny, store: store)
        await clock.waitForSleeper()
        await cache.setIdleTimeout(.seconds(5))
        await clock.waitForSleeper()
        clock.advance(by: .seconds(4))
        let beforeTheNewTimeout = await cache.residentModelNames()
        #expect(beforeTheNewTimeout == [Self.tiny])

        clock.advance(by: .seconds(1))
        await probe.unloads.wait(atLeast: 1, "the unload five seconds in")
        let afterTheNewTimeout = await cache.residentModelNames()
        #expect(afterTheNewTimeout.isEmpty)
    }

    @Test("an unload that found the model leased happens when its last lease comes back")
    func unloadUnleasedWaitsForTheLease() async throws {
        let probe = CacheProbe()
        let cache = StreamingModelCache.probing(probe)
        let store = Self.makeStore()

        let lease = try await cache.borrow(Self.tiny, store: store)
        let unloadedNow = await cache.unloadUnleased()
        #expect(unloadedNow.isEmpty)
        let whileLeased = await cache.residentModelNames()
        #expect(whileLeased == [Self.tiny])

        await lease.release()
        let afterRelease = await cache.residentModelNames()
        #expect(afterRelease.isEmpty)
        await probe.unloads.wait(atLeast: 1, "the unload the lease was holding up")
    }

    @Test("a borrow after an unload request cancels it")
    func borrowClearsThePendingUnload() async throws {
        let probe = CacheProbe()
        let cache = StreamingModelCache.probing(probe)
        let store = Self.makeStore()

        let first = try await cache.borrow(Self.tiny, store: store)
        await cache.unloadUnleased()
        let second = try await cache.borrow(Self.tiny, store: store)
        await first.release()
        await second.release()

        let resident = await cache.residentModelNames()
        #expect(resident == [Self.tiny])
        #expect(probe.unloads.value == 0)
    }

    @Test("unloadAll forgets an evict that was waiting for a lease")
    func unloadAllClearsAWaitingEvict() async throws {
        let probe = CacheProbe()
        let cache = StreamingModelCache.probing(probe)
        let store = Self.makeStore()

        let old = try await cache.borrow(Self.tiny, store: store)
        await cache.evictWhenReleased(Self.tiny)
        await cache.unloadAll()
        let fresh = try await cache.borrow(Self.tiny, store: store)
        await old.release()
        await fresh.release()

        let resident = await cache.residentModelNames()
        #expect(resident == [Self.tiny])
    }

    @Test("an evict during an unborrowed load drops it when it lands")
    func evictDuringAnUnborrowedLoad() async throws {
        let probe = CacheProbe()
        let gate = LoadGate()
        let cache = StreamingModelCache.probing(probe, gate: gate)
        let store = Self.makeStore()

        let warming = GuardedTask { await cache.warm(Self.tiny, store: store) }
        await probe.loads.wait(atLeast: 1, "the warm's load to start")
        await cache.evict(Self.tiny)
        await gate.open(Self.tiny)
        _ = try await warming.value("the warm to finish")

        #expect(await cache.residentModelNames().isEmpty)
    }

    @Test("pressure during an unborrowed load drops it when it lands")
    func pressureDuringAnUnborrowedLoad() async throws {
        let probe = CacheProbe()
        let gate = LoadGate()
        let cache = StreamingModelCache.probing(probe, gate: gate)
        let store = Self.makeStore()

        let warming = GuardedTask { await cache.warm(Self.tiny, store: store) }
        await probe.loads.wait(atLeast: 1, "the warm's load to start")
        #expect(await cache.unloadUnleased().isEmpty, "nothing was resident yet")
        await gate.open(Self.tiny)
        _ = try await warming.value("the warm to finish")

        #expect(await cache.residentModelNames().isEmpty)
    }

    @Test("a borrow that joins a load after pressure marked it keeps the load")
    func borrowJoiningAMarkedLoadKeepsIt() async throws {
        let probe = CacheProbe()
        let gate = LoadGate()
        let cache = StreamingModelCache.probing(probe, gate: gate)
        let store = Self.makeStore()

        let warming = GuardedTask { await cache.warm(Self.tiny, store: store) }
        await probe.loads.wait(atLeast: 1, "the warm's load to start")
        await cache.unloadUnleased()
        let borrowing = GuardedTask { try await cache.borrow(Self.tiny, store: store) }
        await pollUntil("the borrow to join the load") { await cache.leaseCount(for: Self.tiny) == 1 }
        await gate.open(Self.tiny)

        let lease = try #require(try await borrowing.value("the borrow to finish"))
        _ = try await warming.value("the warm to finish")
        #expect(await cache.residentModelNames() == [Self.tiny])
        #expect(probe.loads.value == 1)
        await lease.release()
    }

    @Test("a reload waits for the kit's pending unload")
    func reloadWaitsForThePendingUnload() async throws {
        let probe = CacheProbe()
        let unloadGate = UninterruptibleGate()
        defer { unloadGate.open() }
        let unloaded = TestSignal()
        let reloadsUnderAnUnload = Awaitable(0)
        let cache = StreamingModelCache(
            loader: { _, _ in
                probe.loads.increment()
                return try await StreamingModelCache.makeUnloadedKit()
            },
            reloader: { _ in
                if !unloaded.fired { reloadsUnderAnUnload.increment() }
                probe.reloads.increment()
            },
            unloader: { _ in
                await unloadGate.wait()
                unloaded.fire()
            }
        )
        let store = Self.makeStore()

        let first = try await cache.borrow(Self.tiny, store: store)
        await first.release()
        #expect(await cache.unloadUnleased() == [Self.tiny])
        await unloadGate.arrivals.wait(atLeast: 1, "the unload to start")
        let borrowing = GuardedTask { try await cache.borrow(Self.tiny, store: store) }
        await pollUntil("the borrow to start its reload") { await cache.leaseCount(for: Self.tiny) == 1 }
        #expect(probe.reloads.value == 0, "the reload is parked behind the unload")

        unloadGate.open()
        let second = try #require(try await borrowing.value("the borrow to finish"))
        #expect(second.shared.kit === first.shared.kit)
        #expect(probe.reloads.value == 1)
        #expect(reloadsUnderAnUnload.value == 0)
    }

    @Test("a failed reload drops the kept kit, so the next borrow loads fresh")
    func failedReloadDropsTheKit() async throws {
        struct ReloadFailure: Error {}
        let probe = CacheProbe()
        let cache = StreamingModelCache(
            loader: { _, _ in
                probe.loads.increment()
                return try await StreamingModelCache.makeUnloadedKit()
            },
            reloader: { _ in
                probe.reloads.increment()
                if probe.reloads.value == 1 { throw ReloadFailure() }
            },
            unloader: { _ in probe.unloads.increment() }
        )
        let store = Self.makeStore()

        let first = try await cache.borrow(Self.tiny, store: store)
        await first.release()
        await cache.unloadUnleased()
        await #expect(throws: ReloadFailure.self) { _ = try await cache.borrow(Self.tiny, store: store) }
        #expect(await cache.leaseCount(for: Self.tiny) == 0)

        let second = try await cache.borrow(Self.tiny, store: store)
        #expect(second.shared.kit !== first.shared.kit)
        #expect(probe.loads.value == 2)
        #expect(probe.reloads.value == 1)
    }

    @Test("a lease dropped without release still comes back, and is counted")
    func droppedLeaseComesBack() async throws {
        let clock = TestClock()
        let cache = StreamingModelCache.probing(CacheProbe(), clock: clock)
        let store = Self.makeStore()

        _ = try await cache.borrow(Self.tiny, store: store)
        await clock.waitForSleeper()
        #expect(await cache.leaseCount(for: Self.tiny) == 0)
        #expect(await cache.droppedLeases == 1)
    }

    @Test("release is idempotent")
    func releaseIsIdempotent() async throws {
        let probe = CacheProbe()
        let clock = TestClock()
        let cache = StreamingModelCache.probing(probe, clock: clock)
        let store = Self.makeStore()

        let first = try await cache.borrow(Self.tiny, store: store)
        let second = try await cache.borrow(Self.tiny, store: store)
        await first.release()
        await first.release()
        #expect(await cache.leaseCount(for: Self.tiny) == 1)
        #expect(clock.sleeperCount == 0, "the second lease still holds the model")

        await second.release()
        #expect(await cache.leaseCount(for: Self.tiny) == 0)
        await clock.waitForSleeper()
        #expect(await cache.droppedLeases == 0, "a released lease's deinit returns nothing more")
    }
}
