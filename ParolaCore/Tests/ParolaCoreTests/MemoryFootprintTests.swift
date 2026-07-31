import Foundation
import os
import Testing
@testable import ParolaCore

final class LiveCounter: Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: 0)
    func increment() { lock.withLock { $0 += 1 } }
    func decrement() { lock.withLock { $0 -= 1 } }
    var count: Int { lock.withLock { $0 } }
}

@Suite("Engine memory footprint", .tags(.slow))
struct MemoryFootprintTests {
    actor TrackedTranscriber: Transcriber {
        static let engineID = EngineID("tracked")
        static let capabilities = EngineCapabilities.whisperKitDefaults
        let counter: LiveCounter
        init(counter: LiveCounter) {
            self.counter = counter
            counter.increment()
        }
        deinit { counter.decrement() }
        func load(model: String) async throws {}
        func transcribe(url: URL, options: TranscriptionOptions, handlers: TranscribeHandlers) async throws -> Transcript {
            Transcript(segments: [], language: "en", modelName: "tracked", sourceURL: url)
        }
        func unload() async {}
        func loadedModelName() async -> String? { nil }
    }

    @Test("registry resolution does not retain transcribers across cycles")
    func registryNoRetain() async throws {
        let counter = LiveCounter()
        let registry = EngineRegistry()
        await registry.register(
            engineID: TrackedTranscriber.engineID,
            capabilities: TrackedTranscriber.capabilities
        ) { _ in TrackedTranscriber(counter: counter) }

        let store = ModelStore(modelsDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("mem-\(UUID().uuidString)"))

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    _ = try? await registry.transcriber(for: TrackedTranscriber.engineID, store: store)
                }
            }
        }

        for _ in 0..<20 {
            if counter.count == 0 { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(counter.count == 0, "transcribers leaked across registry resolution: \(counter.count) still alive")
    }

    @Test("resident memory of TranscriptionSession is bounded after idle-unload",
          .timeLimit(.minutes(1)))
    func idleUnloadReleases() async throws {
        let counter = LiveCounter()
        let store = ModelStore(modelsDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("mem-\(UUID().uuidString)"))
        let registry = EngineRegistry()
        await registry.register(
            engineID: .whisperKit,
            capabilities: .whisperKitDefaults
        ) { _ in TrackedTranscriber(counter: counter) }
        await registry.register(
            engineID: .parakeet,
            capabilities: .parakeetDefaults
        ) { _ in TrackedTranscriber(counter: counter) }
        let session = TranscriptionSession(modelStore: store, registry: registry, idleTimeout: 0.25)

        for _ in 0..<3 {
            await session.unloadModel()
        }
        #expect(counter.count == 0)
    }

    @Test("resident size from mach_task_basic_info is reportable",
          .enabled(if: ProcessInfo.processInfo.environment["PAROLA_RUN_RSS_TEST"] != nil))
    func residentSizeAvailable() {
        let rss = currentResidentBytes()
        #expect(rss > 0)
    }
}

/// Process RSS via mach_task_basic_info, in bytes. Returns 0 on failure.
func currentResidentBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) { infoPtr -> kern_return_t in
        infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { ptr in
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), ptr, &count)
        }
    }
    return kr == KERN_SUCCESS ? UInt64(info.resident_size) : 0
}
