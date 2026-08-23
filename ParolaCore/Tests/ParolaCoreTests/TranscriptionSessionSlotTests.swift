import Foundation
import Testing
@testable import ParolaCore

private final class Gate: @unchecked Sendable {
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

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ initial: Value) { stored = initial }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ newValue: Value) {
        lock.lock()
        stored = newValue
        lock.unlock()
    }
}

@Suite("Transcription session slot serialization")
struct TranscriptionSessionSlotTests {
    actor SlotStubTranscriber: Transcriber {
        static let engineID = EngineID.whisperKit
        static let capabilities = EngineCapabilities.whisperKitDefaults

        private let firstLoadGate: Gate?
        private let transcribeGate: Gate?
        fileprivate let firstLoadEntered = LockedBox(false)
        fileprivate let transcribeEntered = LockedBox(false)
        private var loaded: String?
        private var loadCalls = 0

        fileprivate init(firstLoadGate: Gate? = nil, transcribeGate: Gate? = nil) {
            self.firstLoadGate = firstLoadGate
            self.transcribeGate = transcribeGate
        }

        func load(model: String) async throws {
            loadCalls += 1
            if loadCalls == 1, let firstLoadGate {
                firstLoadEntered.set(true)
                await firstLoadGate.wait()
            }
            loaded = model
        }

        func unload() async { loaded = nil }
        func loadedModelName() async -> String? { loaded }

        func transcribe(url: URL, options: TranscriptionOptions, handlers: TranscribeHandlers) async throws -> Transcript {
            transcribeEntered.set(true)
            if let transcribeGate {
                await transcribeGate.wait()
            }
            return Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "ok")],
                language: "en",
                modelName: loaded ?? "?",
                sourceURL: url,
                durationSeconds: 1
            )
        }
    }

    private func makeSession(
        clock: TestClock,
        transcriber: SlotStubTranscriber
    ) async throws -> (session: TranscriptionSession, audioURL: URL) {
        let registry = EngineRegistry()
        await registry.register(
            engineID: .whisperKit,
            capabilities: .whisperKitDefaults
        ) { _ in transcriber }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-slot-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ModelStore(modelsDirectory: dir)
        try store.seedInstalledModel("openai_whisper-tiny")
        let session = TranscriptionSession(modelStore: store, registry: registry, clock: clock)
        let audioURL = dir.appendingPathComponent("input.wav")
        try Data("RIFFstub".utf8).write(to: audioURL)
        return (session, audioURL)
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

    @Test("a prewarm overlapping a transcribe leaves no idle timers armed while the run is in flight")
    func prewarmDoesNotArmTimersMidRun() async throws {
        let loadGate = Gate()
        let transcribeGate = Gate()
        let stub = SlotStubTranscriber(firstLoadGate: loadGate, transcribeGate: transcribeGate)
        let clock = TestClock()
        let (session, audioURL) = try await makeSession(clock: clock, transcriber: stub)

        let prewarmTask = Task { await session.prewarm(modelName: "openai_whisper-tiny") }
        let prewarmLoading = await poll { stub.firstLoadEntered.value }
        #expect(prewarmLoading, "prewarm should reach the gated model load")

        let transcribeTask = Task {
            try await session.transcribe(
                source: FileAudioSource(url: audioURL),
                options: TranscriptionOptions(model: "openai_whisper-tiny")
            )
        }
        try? await Task.sleep(for: .milliseconds(100))

        loadGate.open()
        await prewarmTask.value

        let runStarted = await poll { stub.transcribeEntered.value }
        #expect(runStarted, "the transcribe should reach the engine after prewarm completes")

        let timersQuiescent = await poll(budget: .seconds(2)) {
            guard clock.sleeperCount == 0 else { return false }
            try? await Task.sleep(for: .milliseconds(250))
            return clock.sleeperCount == 0
        }
        #expect(
            timersQuiescent,
            "idle-unload timers must not stay armed while a transcribe holds the slot"
        )

        transcribeGate.open()
        _ = try await transcribeTask.value
    }

    @Test("cancelling a transcribe queued behind a running one returns promptly")
    func cancellingQueuedTranscribeReturnsPromptly() async throws {
        let transcribeGate = Gate()
        let stub = SlotStubTranscriber(transcribeGate: transcribeGate)
        let clock = TestClock()
        let (session, audioURL) = try await makeSession(clock: clock, transcriber: stub)
        let options = TranscriptionOptions(model: "openai_whisper-tiny")

        let runningTask = Task {
            try await session.transcribe(source: FileAudioSource(url: audioURL), options: options)
        }
        let runStarted = await poll { stub.transcribeEntered.value }
        #expect(runStarted, "the first transcribe should reach the gated engine call")

        let queuedOutcome = LockedBox<Result<Transcript, any Error>?>(nil)
        let queuedTask = Task {
            do {
                let transcript = try await session.transcribe(
                    source: FileAudioSource(url: audioURL),
                    options: options
                )
                queuedOutcome.set(.success(transcript))
            } catch {
                queuedOutcome.set(.failure(error))
            }
        }
        try? await Task.sleep(for: .milliseconds(100))

        queuedTask.cancel()
        let returned = await poll(budget: .seconds(2)) { queuedOutcome.value != nil }
        #expect(returned, "a cancelled queued transcribe must not stay suspended behind the running one")
        if case .failure(let error)? = queuedOutcome.value {
            #expect(error is CancellationError, "expected CancellationError, got \(error)")
        } else if returned {
            Issue.record("cancelled queued transcribe unexpectedly succeeded")
        }

        transcribeGate.open()
        _ = try await runningTask.value
    }
}
