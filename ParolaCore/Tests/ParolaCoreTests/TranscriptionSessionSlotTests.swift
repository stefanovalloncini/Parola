import Foundation
import Testing
@testable import ParolaCore

@Suite("Transcription session slot serialization")
struct TranscriptionSessionSlotTests {
    actor SlotStubTranscriber: Transcriber {
        static let engineID = EngineID.whisperKit
        static let capabilities = EngineCapabilities.whisperKitDefaults

        private let firstLoadGate: UninterruptibleGate?
        private let transcribeGate: UninterruptibleGate?
        private var loaded: String?
        private var loadCalls = 0

        init(firstLoadGate: UninterruptibleGate? = nil, transcribeGate: UninterruptibleGate? = nil) {
            self.firstLoadGate = firstLoadGate
            self.transcribeGate = transcribeGate
        }

        func load(model: String) async throws {
            loadCalls += 1
            if loadCalls == 1, let firstLoadGate {
                await firstLoadGate.wait()
            }
            loaded = model
        }

        func unload() async { loaded = nil }
        func loadedModelName() async -> String? { loaded }

        func transcribe(url: URL, options: TranscriptionOptions, handlers: TranscribeHandlers) async throws -> Transcript {
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
        let loadGate = UninterruptibleGate()
        let transcribeGate = UninterruptibleGate()
        defer {
            loadGate.open()
            transcribeGate.open()
        }
        let stub = SlotStubTranscriber(firstLoadGate: loadGate, transcribeGate: transcribeGate)
        let clock = TestClock()
        let (session, audioURL) = try await makeSession(clock: clock, transcriber: stub)

        let prewarm = GuardedTask { await session.prewarm(modelName: "openai_whisper-tiny") }
        await loadGate.arrivals.wait(atLeast: 1, "the prewarm to reach the gated model load")

        let run = GuardedTask {
            try await session.transcribe(
                source: FileAudioSource(url: audioURL),
                options: TranscriptionOptions(model: "openai_whisper-tiny")
            )
        }
        await pollUntil("the transcribe to queue behind the prewarm") { await session.queuedRunCount == 1 }

        loadGate.open()
        _ = try await prewarm.value("the prewarm to finish once its load is let through")
        await transcribeGate.arrivals.wait(atLeast: 1, "the transcribe to reach the engine after the prewarm")

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
        _ = try await run.value("the transcribe to finish once the engine is let through")
    }

    @Test("cancelling a transcribe queued behind a running one returns promptly")
    func cancellingQueuedTranscribeReturnsPromptly() async throws {
        let transcribeGate = UninterruptibleGate()
        defer { transcribeGate.open() }
        let stub = SlotStubTranscriber(transcribeGate: transcribeGate)
        let clock = TestClock()
        let (session, audioURL) = try await makeSession(clock: clock, transcriber: stub)
        let options = TranscriptionOptions(model: "openai_whisper-tiny")

        let running = GuardedTask {
            try await session.transcribe(source: FileAudioSource(url: audioURL), options: options)
        }
        await transcribeGate.arrivals.wait(atLeast: 1, "the first transcribe to reach the gated engine call")

        let queued = GuardedTask {
            try await session.transcribe(source: FileAudioSource(url: audioURL), options: options)
        }
        await pollUntil("the second transcribe to queue behind the running one") { await session.queuedRunCount == 1 }

        queued.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await queued.value("the cancelled transcribe to return while the running one holds the slot")
        }

        transcribeGate.open()
        _ = try await running.value("the running transcribe to finish once the engine is let through")
    }
}
