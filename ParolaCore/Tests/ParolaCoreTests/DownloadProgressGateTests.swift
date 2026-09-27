import Foundation
import Testing
import os
@testable import ParolaCore

@Suite("Model download progress")
struct DownloadProgressGateTests {
    private final class Readings: Sendable {
        private let values = OSAllocatedUnfairLock(initialState: [Double]())
        func append(_ value: Double) { values.withLock { $0.append(value) } }
        var all: [Double] { values.withLock { $0 } }
    }

    private func makeStore() throws -> ModelStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-progress-gate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return ModelStore(modelsDirectory: dir)
    }

    @Test("a download reports once per whole percent, never lower than before, and ends at one")
    func downloadGatesItsProgress() async throws {
        let store = try makeStore()
        let registry = EngineRegistry()
        let chunks: [Double] = [0, 0.001, 0.004, 0.01, 0.5, 0.2, 0.505, 0.51, 0.999]
        await registry.register(
            engineID: .whisperKit,
            capabilities: .whisperKitDefaults,
            factory: { _ in fatalError("factory unused") },
            downloader: { variant, store, progress in
                for chunk in chunks { progress?(chunk) }
                let destination = store.installedURL(for: variant)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                return destination
            }
        )
        let readings = Readings()

        _ = try await store.download(variant: "openai_whisper-tiny", progress: { readings.append($0) }, registry: registry)

        #expect(readings.all == [0, 0.01, 0.5, 0.51, 0.999, 1])
    }

    @Test("readings past either end are held to the bar")
    func readingsAreClamped() {
        let readings = Readings()
        let report = DownloadProgressGate.gating { readings.append($0) }

        for fraction in [-0.5, 0, 1.7, 1] { report(fraction) }

        #expect(readings.all == [0, 1])
    }
}
