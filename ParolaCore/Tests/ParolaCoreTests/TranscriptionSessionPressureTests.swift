import Foundation
import Testing
@testable import ParolaCore

@Suite("Transcription session memory pressure")
struct TranscriptionSessionPressureTests {
    actor GatedTranscriber: Transcriber {
        static let engineID = EngineID.whisperKit
        static let capabilities = EngineCapabilities.whisperKitDefaults

        nonisolated let loadGate = UninterruptibleGate()
        nonisolated let transcribeGate = UninterruptibleGate()
        nonisolated let unloads = Awaitable(0)
        private let gatesLoad: Bool
        private let endsCancelled: Bool
        private var loaded: String?

        init(gatesLoad: Bool = false, endsCancelled: Bool = false) {
            self.gatesLoad = gatesLoad
            self.endsCancelled = endsCancelled
        }

        func load(model: String) async throws {
            if gatesLoad { await loadGate.wait() }
            loaded = model
        }

        func unload() async {
            loaded = nil
            unloads.increment()
        }

        func loadedModelName() async -> String? { loaded }

        func transcribe(url: URL, options: TranscriptionOptions, handlers: TranscribeHandlers) async throws -> Transcript {
            await transcribeGate.wait()
            if endsCancelled { throw CancellationError() }
            return Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "ok")],
                language: "en",
                modelName: loaded ?? "?",
                sourceURL: url,
                durationSeconds: 1
            )
        }

        func openGates() {
            loadGate.open()
            transcribeGate.open()
        }
    }

    private static let tiny = "openai_whisper-tiny"

    private func makeSession(
        clock: TestClock,
        transcriber: GatedTranscriber,
        abandonGrace: Duration = .seconds(5)
    ) async throws -> (session: TranscriptionSession, audioURL: URL) {
        let registry = EngineRegistry()
        await registry.register(
            engineID: .whisperKit,
            capabilities: .whisperKitDefaults
        ) { _ in transcriber }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-pressure-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ModelStore(modelsDirectory: dir)
        try store.seedInstalledModel(Self.tiny)
        let session = TranscriptionSession(
            modelStore: store, registry: registry, clock: clock, abandonGrace: abandonGrace
        )
        let audioURL = dir.appendingPathComponent("input.wav")
        try Data("RIFFstub".utf8).write(to: audioURL)
        return (session, audioURL)
    }

    private func transcribe(_ session: TranscriptionSession, _ audioURL: URL) async throws -> Transcript {
        try await session.transcribe(
            source: FileAudioSource(url: audioURL),
            options: TranscriptionOptions(model: Self.tiny)
        )
    }

    @Test("pressure with no run unloads at once")
    func pressureWhileIdleUnloads() async throws {
        let stub = GatedTranscriber()
        await stub.openGates()
        let clock = TestClock()
        let (session, audioURL) = try await makeSession(clock: clock, transcriber: stub)
        _ = try await transcribe(session, audioURL)

        await session.unloadUnderPressure()
        #expect(stub.unloads.value == 1)
        #expect(await session.currentModel() == nil)
    }

    @Test("pressure during a run unloads after the run, not during it")
    func pressureDuringARunWaitsForItsEnd() async throws {
        let stub = GatedTranscriber()
        let clock = TestClock()
        let (session, audioURL) = try await makeSession(clock: clock, transcriber: stub)
        let run = GuardedTask { try await transcribe(session, audioURL) }
        defer { stub.transcribeGate.open() }
        await stub.transcribeGate.arrivals.wait(atLeast: 1, "the run to reach the engine")

        await session.unloadUnderPressure()
        #expect(await session.currentModel() == Self.tiny, "the running run keeps its model")
        #expect(stub.unloads.value == 0)

        stub.transcribeGate.open()
        _ = try await run.value("the run to finish")
        await stub.unloads.wait(atLeast: 1, "the unload the pressure deferred to the run's end")
        #expect(await session.currentModel() == nil)
        #expect(clock.sleeperCount == 0, "the run's end unloads instead of arming the idle timers")
    }

    @Test("pressure during a prewarm unloads once the prewarm ends")
    func pressureDuringAPrewarmWaitsForItsEnd() async throws {
        let stub = GatedTranscriber(gatesLoad: true)
        let clock = TestClock()
        let (session, _) = try await makeSession(clock: clock, transcriber: stub)
        let prewarm = GuardedTask { await session.prewarm(modelName: Self.tiny) }
        defer { stub.loadGate.open() }
        await stub.loadGate.arrivals.wait(atLeast: 1, "the prewarm to reach the model load")

        await session.unloadUnderPressure()
        #expect(stub.unloads.value == 0)

        stub.loadGate.open()
        _ = try await prewarm.value("the prewarm to finish")
        await stub.unloads.wait(atLeast: 1, "the unload the pressure deferred to the prewarm's end")
        #expect(await session.currentModel() == nil)
    }

    @Test("pressure during a run that gets abandoned unloads once its slot is taken back")
    func pressureDuringAnAbandonedRun() async throws {
        let stub = GatedTranscriber(endsCancelled: true)
        let clock = TestClock()
        let (session, audioURL) = try await makeSession(
            clock: clock, transcriber: stub, abandonGrace: .milliseconds(50)
        )
        defer { stub.transcribeGate.open() }
        let stalled = Task { try await transcribe(session, audioURL) }
        await stub.transcribeGate.arrivals.wait(atLeast: 1, "the run to park in the engine")

        await session.unloadUnderPressure()
        #expect(await session.diarizer.unloadCount == 0)
        #expect(stub.unloads.value == 0)
        stalled.cancel()

        await pollUntil("the deferred unload once the abandoned run lets go of the slot") {
            await session.diarizer.unloadCount >= 1
        }
        #expect(await session.currentModel() == nil)
    }

    @Test("an unload during the run answers its pressure, so the run's end arms the idle timers")
    func anUnloadDuringTheRunAnswersThePressure() async throws {
        let stub = GatedTranscriber()
        let clock = TestClock()
        let (session, audioURL) = try await makeSession(clock: clock, transcriber: stub)
        let run = GuardedTask { try await transcribe(session, audioURL) }
        defer { stub.transcribeGate.open() }
        await stub.transcribeGate.arrivals.wait(atLeast: 1, "the run to reach the engine")

        await session.unloadUnderPressure()
        await session.unloadModel()
        #expect(await session.diarizer.unloadCount == 1)

        stub.transcribeGate.open()
        _ = try await run.value("the run to finish")
        await clock.waitForSleeper(count: 2, timeout: .seconds(5))
        #expect(await session.diarizer.unloadCount == 1, "no second unload at the run's end")
    }

    @Test("unloadModel(ifLoaded:) skips a running run")
    func unloadIfLoadedSkipsARunningRun() async throws {
        let stub = GatedTranscriber()
        let clock = TestClock()
        let (session, audioURL) = try await makeSession(clock: clock, transcriber: stub)
        let run = GuardedTask { try await transcribe(session, audioURL) }
        defer { stub.transcribeGate.open() }
        await stub.transcribeGate.arrivals.wait(atLeast: 1, "the run to reach the engine")

        await session.unloadModel(ifLoaded: Self.tiny)
        #expect(await session.currentModel() == Self.tiny)
        #expect(stub.unloads.value == 0)

        stub.transcribeGate.open()
        _ = try await run.value("the run to finish")
        await session.unloadModel(ifLoaded: "openai_whisper-base")
        #expect(await session.currentModel() == Self.tiny, "another model's name leaves this one loaded")

        await session.unloadModel(ifLoaded: Self.tiny)
        #expect(await session.currentModel() == nil)
        #expect(stub.unloads.value == 1)
    }
}
