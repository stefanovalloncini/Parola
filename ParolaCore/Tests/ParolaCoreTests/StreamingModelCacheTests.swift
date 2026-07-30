import Foundation
import Testing
@preconcurrency import WhisperKit
@testable import ParolaCore

@Suite("Streaming model cache")
struct StreamingModelCacheTests {
    private actor LoadCounter {
        private(set) var count = 0
        func increment() { count += 1 }
    }

    private static func makeUnloadedKit() async throws -> SharedWhisperKit {
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

    private static func makeCache(counting counter: LoadCounter) -> StreamingModelCache {
        StreamingModelCache { _, _ in
            await counter.increment()
            return try await makeUnloadedKit()
        }
    }

    private static func makeStore() -> ModelStore {
        ModelStore(modelsDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("streaming-cache-tests-\(UUID().uuidString)"))
    }

    @Test("concurrent borrows of the same model share one load")
    func concurrentBorrowsSingleFlight() async throws {
        let counter = LoadCounter()
        let cache = Self.makeCache(counting: counter)
        let store = Self.makeStore()

        let identities = try await withThrowingTaskGroup(of: ObjectIdentifier.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    ObjectIdentifier(try await cache.borrow("openai_whisper-tiny", store: store).kit)
                }
            }
            return try await group.reduce(into: [ObjectIdentifier]()) { $0.append($1) }
        }

        #expect(Set(identities).count == 1)
        #expect(await counter.count == 1)
    }

    @Test("sequential borrows reuse the loaded instance")
    func sequentialBorrowsReuse() async throws {
        let counter = LoadCounter()
        let cache = Self.makeCache(counting: counter)
        let store = Self.makeStore()

        let first = try await cache.borrow("openai_whisper-tiny", store: store)
        let second = try await cache.borrow("openai_whisper-tiny", store: store)

        #expect(first.kit === second.kit)
        #expect(await counter.count == 1)
    }

    @Test("different models load independently")
    func differentModelsLoadSeparately() async throws {
        let counter = LoadCounter()
        let cache = Self.makeCache(counting: counter)
        let store = Self.makeStore()

        let tiny = try await cache.borrow("openai_whisper-tiny", store: store)
        let base = try await cache.borrow("openai_whisper-base", store: store)

        #expect(tiny.kit !== base.kit)
        #expect(await counter.count == 2)
    }

    @Test("unloadAll evicts and the next borrow reloads")
    func unloadAllEvictsAndReloads() async throws {
        let counter = LoadCounter()
        let cache = Self.makeCache(counting: counter)
        let store = Self.makeStore()

        let first = try await cache.borrow("openai_whisper-tiny", store: store)
        await cache.unloadAll()
        let second = try await cache.borrow("openai_whisper-tiny", store: store)

        #expect(first.kit !== second.kit)
        #expect(await counter.count == 2)
    }

    @Test("a failed load is not cached, the next borrow retries")
    func failedLoadRetries() async throws {
        struct LoadFailure: Error {}
        let counter = LoadCounter()
        let cache = StreamingModelCache { _, _ in
            await counter.increment()
            if await counter.count == 1 { throw LoadFailure() }
            return try await Self.makeUnloadedKit()
        }
        let store = Self.makeStore()

        await #expect(throws: LoadFailure.self) {
            _ = try await cache.borrow("openai_whisper-tiny", store: store)
        }
        _ = try await cache.borrow("openai_whisper-tiny", store: store)

        #expect(await counter.count == 2)
    }

    private actor LoadGate {
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

    @Test("a load superseded by a switch to another model is not cached")
    func supersededLoadNotCached() async throws {
        let counter = LoadCounter()
        let gate = LoadGate()
        let cache = StreamingModelCache { name, _ in
            await counter.increment()
            await gate.wait(name)
            return try await Self.makeUnloadedKit()
        }
        let store = Self.makeStore()

        async let tiny = cache.borrow("openai_whisper-tiny", store: store)
        while await counter.count < 1 { try await Task.sleep(for: .milliseconds(1)) }
        async let small = cache.borrow("openai_whisper-small", store: store)
        while await counter.count < 2 { try await Task.sleep(for: .milliseconds(1)) }

        // The superseded tiny load lands after small was requested; only small may stay cached.
        await gate.open("openai_whisper-tiny")
        _ = try await tiny
        await gate.open("openai_whisper-small")
        _ = try await small

        _ = try await cache.borrow("openai_whisper-small", store: store)
        #expect(await counter.count == 2, "the latest borrow stays cached")

        _ = try await cache.borrow("openai_whisper-tiny", store: store)
        #expect(await counter.count == 3, "the superseded load must not have been cached")
    }

    @Test("borrowing a different model evicts the previous one")
    func borrowEvictsOtherModels() async throws {
        let counter = LoadCounter()
        let cache = Self.makeCache(counting: counter)
        let store = Self.makeStore()

        _ = try await cache.borrow("openai_whisper-tiny", store: store)
        _ = try await cache.borrow("openai_whisper-tiny", store: store)
        #expect(await counter.count == 1)

        _ = try await cache.borrow("openai_whisper-small", store: store)
        #expect(await counter.count == 2)

        _ = try await cache.borrow("openai_whisper-tiny", store: store)
        #expect(await counter.count == 3, "switching back reloads: the switch away must have freed the old instance")
    }
}
