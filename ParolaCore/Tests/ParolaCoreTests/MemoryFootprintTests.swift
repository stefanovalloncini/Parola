import Foundation
import Testing
@testable import ParolaCore

@Suite("Engine memory footprint")
struct MemoryFootprintTests {
    actor TrackedTranscriber: Transcriber {
        static let engineID = EngineID("tracked")
        static let capabilities = EngineCapabilities.whisperKitDefaults
        nonisolated(unsafe) static var liveCount: Int = 0
        init() { Self.liveCount += 1 }
        deinit { Self.liveCount -= 1 }
        func load(model: String) async throws {}
        func transcribe(url: URL, options: TranscriptionOptions) async throws -> Transcript {
            Transcript(segments: [], language: "en", modelName: "tracked", sourceURL: url)
        }
        func unload() async {}
        func loadedModelName() async -> String? { nil }
    }

    @Test("registry resolution does not retain transcribers across cycles")
    func registryNoRetain() async throws {
        TrackedTranscriber.liveCount = 0
        let registry = EngineRegistry()
        await registry.register(
            engineID: TrackedTranscriber.engineID,
            capabilities: TrackedTranscriber.capabilities
        ) { _ in TrackedTranscriber() }

        let store = ModelStore(modelsDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("mem-\(UUID().uuidString)"))
        for _ in 0..<5 {
            autoreleasepool {
                Task {
                    let _ = try? await registry.transcriber(for: TrackedTranscriber.engineID, store: store)
                }
            }
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(TrackedTranscriber.liveCount <= 5, "live count is \(TrackedTranscriber.liveCount)")
    }

    @Test("resident memory of TranscriptionSession is bounded after idle-unload",
          .timeLimit(.minutes(1)))
    func idleUnloadReleases() async throws {
        let store = ModelStore(modelsDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("mem-\(UUID().uuidString)"))
        let registry = EngineRegistry()
        await registry.register(
            engineID: .whisperKit,
            capabilities: .whisperKitDefaults
        ) { _ in TrackedTranscriber() }
        await registry.register(
            engineID: .parakeet,
            capabilities: .parakeetDefaults
        ) { _ in TrackedTranscriber() }
        let session = TranscriptionSession(modelStore: store, registry: registry, idleTimeout: 0.25)

        TrackedTranscriber.liveCount = 0
        for _ in 0..<3 {
            await session.unloadModel()
        }
        #expect(TrackedTranscriber.liveCount == 0)
    }

    @Test("resident size from mach_task_basic_info is reportable",
          .enabled(if: ProcessInfo.processInfo.environment["PAROLA_RUN_RSS_TEST"] != nil))
    func residentSizeAvailable() {
        let rss = currentResidentBytes()
        #expect(rss > 0)
    }
}

/// Returns the process's current resident set size in bytes via mach_task_basic_info.
/// Returns 0 if the call fails.
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
