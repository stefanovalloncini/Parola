import Foundation
import Testing
@testable import ParolaCore

@Suite("Whisper padding is clamped on the session path", .serialized)
struct TranscriptionSessionClampTests {
    actor SeedTranscriber: Transcriber {
        static let engineID = EngineID.whisperKit
        static let capabilities = EngineCapabilities.whisperKitDefaults

        private let engine: EngineID
        private let seed: [TranscriptSegment]
        private var loaded: String?

        fileprivate init(engine: EngineID, seed: [TranscriptSegment]) {
            self.engine = engine
            self.seed = seed
        }

        func load(model: String) async throws { loaded = model }
        func unload() async { loaded = nil }
        func loadedModelName() async -> String? { loaded }

        func transcribe(
            url: URL, options: TranscriptionOptions, handlers: TranscribeHandlers
        ) async throws -> Transcript {
            Transcript(
                segments: seed,
                language: "it",
                modelName: loaded ?? "?",
                sourceURL: url,
                durationSeconds: 100
            )
        }
    }

    private func run(engine: EngineID, model: String) async throws -> Transcript {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-clamp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let audioURL = dir.appendingPathComponent("input.wav")
        try Data("RIFFstub".utf8).write(to: audioURL)

        let seed = [
            TranscriptSegment(id: 0, start: 0, end: 21, text: "Grazie a tutti."),
            TranscriptSegment(id: 1, start: 21, end: 25, text: "parliamo del grafico"),
        ]
        let registry = EngineRegistry()
        let stub = SeedTranscriber(engine: engine, seed: seed)
        await registry.register(engineID: engine, capabilities: .whisperKitDefaults) { _ in stub }
        let store = ModelStore(modelsDirectory: dir)
        try store.seedInstalledModel(model)
        let session = TranscriptionSession(modelStore: store, registry: registry)
        return try await session.transcribe(
            source: FileAudioSource(url: audioURL),
            options: TranscriptionOptions(model: model, language: "it")
        )
    }

    @Test("a Whisper run comes back with the padded span cut")
    func whisperRunIsClamped() async throws {
        let transcript = try await run(engine: .whisperKit, model: "openai_whisper-tiny")
        let padded = try #require(transcript.segments.first { $0.text == "Grazie a tutti." })
        #expect(padded.end == 3)
    }

    @Test("another engine's spans are left alone")
    func otherEnginesAreNotClamped() async throws {
        let transcript = try await run(
            engine: .appleSpeech, model: AppleSpeechTranscriber.syntheticModelID
        )
        let padded = try #require(transcript.segments.first { $0.text == "Grazie a tutti." })
        #expect(padded.end == 21)
    }
}
