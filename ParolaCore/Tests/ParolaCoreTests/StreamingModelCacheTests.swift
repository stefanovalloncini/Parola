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
}
