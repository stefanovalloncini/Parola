import Foundation
import Testing
@testable import ParolaCore

// @unchecked is safe: the only state is `opened`/`waiters`, guarded by the lock.
private final class AbandonGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        lock.lock()
        opened = true
        let due = waiters
        waiters = []
        lock.unlock()
        for waiter in due { waiter.resume() }
    }

    /// Deliberately not cancellation-aware: it stands in for an engine parked in a blocking read.
    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if opened {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

// @unchecked is safe: the only state is `count`, guarded by the lock.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    @discardableResult
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}

@Suite("Transcription session abandons a stalled cancel", .serialized)
struct TranscriptionSessionAbandonTests {
    actor StallingTranscriber: Transcriber {
        static let engineID = EngineID.whisperKit
        static let capabilities = EngineCapabilities.whisperKitDefaults

        private let gate: AbandonGate
        private let entered: Counter
        private var loaded: String?

        fileprivate init(gate: AbandonGate, entered: Counter) {
            self.gate = gate
            self.entered = entered
        }

        func load(model: String) async throws { loaded = model }
        func unload() async { loaded = nil }
        func loadedModelName() async -> String? { loaded }

        func transcribe(
            url: URL, options: TranscriptionOptions, handlers: TranscribeHandlers
        ) async throws -> Transcript {
            entered.increment()
            await gate.wait()
            throw CancellationError()
        }
    }

    actor QuickTranscriber: Transcriber {
        static let engineID = EngineID.whisperKit
        static let capabilities = EngineCapabilities.whisperKitDefaults

        private var loaded: String?

        func load(model: String) async throws { loaded = model }
        func unload() async { loaded = nil }
        func loadedModelName() async -> String? { loaded }

        func transcribe(
            url: URL, options: TranscriptionOptions, handlers: TranscribeHandlers
        ) async throws -> Transcript {
            Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "second run")],
                language: "en",
                modelName: loaded ?? "?",
                sourceURL: url,
                durationSeconds: 1
            )
        }
    }

    @Test("a cancelled run parked in the engine hands its slot to the next one")
    func stalledCancelDoesNotPoisonThePipeline() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-abandon-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let audioURL = dir.appendingPathComponent("input.wav")
        try Data("RIFFstub".utf8).write(to: audioURL)

        let gate = AbandonGate()
        defer { gate.open() }
        let entered = Counter()
        let handedOut = Counter()
        let stalling = StallingTranscriber(gate: gate, entered: entered)
        let quick = QuickTranscriber()

        let registry = EngineRegistry()
        await registry.register(
            engineID: .whisperKit,
            capabilities: .whisperKitDefaults
        ) { _ in
            handedOut.increment() == 1 ? (stalling as any Transcriber) : quick
        }
        let store = ModelStore(modelsDirectory: dir)
        try store.seedInstalledModel("openai_whisper-tiny")
        let session = TranscriptionSession(
            modelStore: store,
            registry: registry,
            abandonGrace: .milliseconds(200)
        )
        let options = TranscriptionOptions(model: "openai_whisper-tiny")

        let stalled = Task {
            try await session.transcribe(source: FileAudioSource(url: audioURL), options: options)
        }
        while entered.value == 0 { try await Task.sleep(for: .milliseconds(10)) }
        stalled.cancel()

        let started = ContinuousClock.now
        let transcript = try await session.transcribe(
            source: FileAudioSource(url: audioURL), options: options
        )
        let elapsed = started.duration(to: .now)
        #expect(transcript.segments.first?.text == "second run")
        #expect(elapsed < .seconds(5), "the next run waited \(elapsed) on the abandoned one")
        #expect(handedOut.value == 2, "the abandoned run's transcriber must not be reused")
    }
}
