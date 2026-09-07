import Foundation
import Testing
@testable import ParolaCore

@Suite("Transcription session file-read deadline", .serialized)
struct TranscriptionSessionFileReadTests {
    actor StubTranscriber: Transcriber {
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
                segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "ok")],
                language: "en",
                modelName: loaded ?? "?",
                sourceURL: url,
                durationSeconds: 1
            )
        }
    }

    private func makeSession(
        in directory: URL
    ) async throws -> TranscriptionSession {
        let registry = EngineRegistry()
        let stub = StubTranscriber()
        await registry.register(
            engineID: .whisperKit,
            capabilities: .whisperKitDefaults
        ) { _ in stub }
        let store = ModelStore(modelsDirectory: directory)
        try store.seedInstalledModel("openai_whisper-tiny")
        return TranscriptionSession(
            modelStore: store,
            registry: registry,
            fileReadDeadline: .seconds(3)
        )
    }

    /// A FIFO with no writer parks `open()` exactly the way a TCC-denied folder or a stalled
    /// share does, and neither one can be cancelled out of.
    @Test("a file that never opens fails the run and leaves the next one free to start")
    func wedgedOpenFailsAndFreesThePipeline() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-fileread-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let wedged = dir.appendingPathComponent("wedged.wav")
        #expect(mkfifo(wedged.path, 0o644) == 0, "could not create the FIFO the test needs")
        defer {
            let writer = open(wedged.path, O_WRONLY | O_NONBLOCK)
            if writer >= 0 { close(writer) }
        }

        let readable = dir.appendingPathComponent("readable.wav")
        try Data("RIFFstub".utf8).write(to: readable)

        let session = try await makeSession(in: dir)
        let options = TranscriptionOptions(model: "openai_whisper-tiny")

        do {
            _ = try await session.transcribe(source: FileAudioSource(url: wedged), options: options)
            Issue.record("a run on a file that never opens should fail")
        } catch let error as ParolaError {
            guard case .fileReadTimedOut(let name) = error else {
                Issue.record("expected fileReadTimedOut, got \(error)")
                return
            }
            #expect(name == "wedged.wav")
        } catch {
            Issue.record("expected fileReadTimedOut, got \(error)")
            return
        }

        let started = ContinuousClock.now
        let transcript = try await session.transcribe(
            source: FileAudioSource(url: readable), options: options
        )
        let elapsed = started.duration(to: .now)
        #expect(transcript.segments.count == 1)
        #expect(elapsed < .seconds(5), "the next run waited \(elapsed) behind the wedged one")
    }
}
