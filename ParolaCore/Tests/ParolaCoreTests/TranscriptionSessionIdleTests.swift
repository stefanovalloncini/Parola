import Foundation
import Testing
@testable import ParolaCore

@Suite("Transcription session idle policy")
struct TranscriptionSessionIdleTests {
    actor IdleStubTranscriber: Transcriber {
        static let engineID = EngineID.whisperKit
        static let capabilities = EngineCapabilities.whisperKitDefaults

        private var loaded: String?

        func load(model: String) async throws { loaded = model }
        func unload() async { loaded = nil }
        func loadedModelName() async -> String? { loaded }

        func transcribe(url: URL, options: TranscriptionOptions, handlers: TranscribeHandlers) async throws -> Transcript {
            Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "ok")],
                language: "en",
                modelName: loaded ?? "?",
                sourceURL: url,
                durationSeconds: 1
            )
        }
    }

    private func makeSession(clock: TestClock) async throws -> (session: TranscriptionSession, audioURL: URL) {
        let registry = EngineRegistry()
        await registry.register(
            engineID: .whisperKit,
            capabilities: .whisperKitDefaults
        ) { _ in IdleStubTranscriber() }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-idle-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ModelStore(modelsDirectory: dir)
        try store.seedInstalledModel("openai_whisper-tiny")
        let session = TranscriptionSession(
            modelStore: store, registry: registry, clock: clock, observesMemoryPressure: false
        )
        let audioURL = dir.appendingPathComponent("input.wav")
        try Data("RIFFstub".utf8).write(to: audioURL)
        return (session, audioURL)
    }

    private func poll(
        budget: Duration = .seconds(10),
        until condition: @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + budget
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }

    @Test("diarizer unloads at its short idle while the model stays warm; model unloads at the long idle")
    func splitIdleUnload() async throws {
        let clock = TestClock()
        let (session, audioURL) = try await makeSession(clock: clock)
        _ = try await session.transcribe(
            source: FileAudioSource(url: audioURL),
            options: TranscriptionOptions(model: "openai_whisper-tiny")
        )

        let bothTimersArmed = await poll { clock.sleeperCount == 2 }
        #expect(bothTimersArmed, "expected separate diarizer and model idle timers")

        clock.advance(by: .seconds(60))
        let diarizerDropped = await poll { await session.diarizer.unloadCount >= 1 }
        #expect(diarizerDropped, "diarizer should unload at the 60s idle")
        #expect(await session.currentModel() == "openai_whisper-tiny", "ASR model must stay warm past the diarizer idle")

        clock.advance(by: .seconds(540))
        let modelDropped = await poll { await session.currentModel() == nil }
        #expect(modelDropped, "ASR model should unload at the 600s idle")
    }

    @Test("a new transcribe within the diarizer idle window rearms both timers")
    func newWorkRearmsTimers() async throws {
        let clock = TestClock()
        let (session, audioURL) = try await makeSession(clock: clock)
        let options = TranscriptionOptions(model: "openai_whisper-tiny")
        _ = try await session.transcribe(source: FileAudioSource(url: audioURL), options: options)
        _ = await poll { clock.sleeperCount == 2 }

        clock.advance(by: .seconds(30))
        _ = try await session.transcribe(source: FileAudioSource(url: audioURL), options: options)
        _ = await poll { clock.sleeperCount == 2 }

        clock.advance(by: .seconds(45))
        try? await Task.sleep(for: .milliseconds(200))
        #expect(await session.diarizer.unloadCount == 0, "75s after first use but 45s after the last: no unload yet")
        #expect(await session.currentModel() == "openai_whisper-tiny")

        await session.unloadModel()
    }
}
