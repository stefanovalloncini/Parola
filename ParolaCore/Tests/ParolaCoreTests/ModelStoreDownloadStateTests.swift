import Foundation
import Testing
@testable import ParolaCore

private final class DownloadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _invocations = 0
    private var _shouldFail = true
    private var _entered = false
    private var _released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var invocations: Int {
        lock.lock(); defer { lock.unlock() }
        return _invocations
    }

    var entered: Bool {
        lock.lock(); defer { lock.unlock() }
        return _entered
    }

    func recordInvocation() {
        lock.lock()
        _invocations += 1
        _entered = true
        lock.unlock()
    }

    var shouldFail: Bool {
        lock.lock(); defer { lock.unlock() }
        return _shouldFail
    }

    func setShouldFail(_ fail: Bool) {
        lock.lock()
        _shouldFail = fail
        lock.unlock()
    }

    func release() {
        lock.lock()
        _released = true
        let due = waiters
        waiters = []
        lock.unlock()
        for waiter in due { waiter.resume() }
    }

    func waitForRelease() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if _released {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

// Gated: its downloader throws on purpose, and that failure is now logged — an error record
// drains whatever file sink another suite has installed.
@Suite("Model store download state", .logFacade)
struct ModelStoreDownloadStateTests {
    private static let variant = "openai_whisper-tiny"

    private func makeStore() throws -> ModelStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-download-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return ModelStore(modelsDirectory: dir)
    }

    private func registerDownloader(
        in registry: EngineRegistry,
        probe: DownloadProbe,
        blockUntilReleased: Bool = false
    ) async {
        await registry.register(
            engineID: .whisperKit,
            capabilities: .whisperKitDefaults,
            factory: { _ in fatalError("factory unused") },
            downloader: { variant, store, _ in
                probe.recordInvocation()
                let destination = store.installedURL(for: variant)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                try Data("partial-weights".utf8).write(
                    to: destination.appendingPathComponent("model.mlmodelc")
                )
                if blockUntilReleased {
                    await probe.waitForRelease()
                }
                if probe.shouldFail {
                    throw ParolaError.modelDownloadFailed("test", underlying: "network dropped")
                }
                return destination
            }
        )
    }

    private func poll(
        budget: Duration = .seconds(5),
        until condition: @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + budget
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }

    @Test("a failed registry download is not recorded as installed and the next attempt re-runs the downloader")
    func failedDownloadIsRetriable() async throws {
        let store = try makeStore()
        let registry = EngineRegistry()
        let probe = DownloadProbe()
        await registerDownloader(in: registry, probe: probe)

        await #expect(throws: (any Error).self) {
            _ = try await store.download(variant: Self.variant, registry: registry)
        }
        #expect(
            !store.isInstalled(Self.variant),
            "a partial directory left by a failed download must not count as installed"
        )

        probe.setShouldFail(false)
        _ = try await store.download(variant: Self.variant, registry: registry)
        #expect(probe.invocations == 2, "the retry must reach the downloader, not early-return")
        #expect(store.isInstalled(Self.variant), "a completed download counts as installed")
    }

    @Test("a registry download cancelled mid-flight is not recorded as installed even if the downloader returns success")
    func cancelledDownloadIsNotInstalled() async throws {
        let store = try makeStore()
        let registry = EngineRegistry()
        let probe = DownloadProbe()
        probe.setShouldFail(false)
        await registerDownloader(in: registry, probe: probe, blockUntilReleased: true)

        let downloadTask = Task {
            try await store.download(variant: Self.variant, registry: registry)
        }
        let started = await poll { probe.entered }
        #expect(started, "the downloader should be reached")

        downloadTask.cancel()
        probe.release()

        let outcome = await downloadTask.result
        #expect(throws: CancellationError.self) { try outcome.get() }
        #expect(
            !store.isInstalled(Self.variant),
            "a cancelled download must not count as installed even when the downloader returns cleanly"
        )
    }
}
