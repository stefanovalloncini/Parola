import Foundation
import Testing
@testable import ParolaCore

@Suite("The session drops options an engine can't honor", .serialized)
struct UnsupportedOptionStripTests {
    private actor OptionsRecorder: Transcriber {
        static let engineID = EngineID.appleSpeech
        static let capabilities = EngineCapabilities.appleSpeechDefaults

        private(set) var received: TranscriptionOptions?
        private var loaded: String?

        func load(model: String) async throws { loaded = model }
        func unload() async { loaded = nil }
        func loadedModelName() async -> String? { loaded }

        func transcribe(url: URL, options: TranscriptionOptions, handlers: TranscribeHandlers) async throws -> Transcript {
            received = options
            return Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "ciao")],
                language: "it",
                modelName: loaded ?? "?",
                sourceURL: url
            )
        }
    }

    private func run(
        engine: EngineID, capabilities: EngineCapabilities, model: String, options: TranscriptionOptions
    ) async throws -> TranscriptionOptions? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-strip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let audioURL = dir.appendingPathComponent("input.wav")
        try Data("RIFFstub".utf8).write(to: audioURL)

        let recorder = OptionsRecorder()
        let registry = EngineRegistry()
        await registry.register(engineID: engine, capabilities: capabilities) { _ in recorder }
        let store = ModelStore(modelsDirectory: dir)
        try store.seedInstalledModel(model)
        let session = TranscriptionSession(modelStore: store, registry: registry)
        var options = options
        options.model = model
        _ = try await session.transcribe(source: FileAudioSource(url: audioURL), options: options)
        return await recorder.received
    }

    @Test("Apple Speech runs without the prompt and the word timings it can't use, and says so")
    func appleSpeechDropsPromptAndWords() async throws {
        let sink = CapturingDiagnosticsSink()
        let received = try await ParolaLog.withSink(sink) {
            try await run(
                engine: .appleSpeech,
                capabilities: .appleSpeechDefaults,
                model: AppleSpeechTranscriber.syntheticModelID,
                options: TranscriptionOptions(language: "it", wordTimestamps: true, initialPrompt: "Parola")
            )
        }

        #expect(received?.initialPrompt == nil)
        #expect(received?.wordTimestamps == false)
        let notices = sink.records.filter { $0.category == .models && $0.level == .notice }.map(\.message.rendered)
        #expect(notices.contains("engine apple-speech takes no prompt; dropped it"))
        #expect(notices.contains("engine apple-speech emits no word timings; dropped the request"))
    }

    @Test("Parakeet keeps word timings and drops only the prompt")
    func parakeetDropsOnlyThePrompt() async throws {
        let received = try await run(
            engine: .parakeet,
            capabilities: .parakeetDefaults,
            model: "nvidia_parakeet-tdt-0.6b-v3",
            options: TranscriptionOptions(language: "it", wordTimestamps: true, initialPrompt: "Parola")
        )

        #expect(received?.initialPrompt == nil)
        #expect(received?.wordTimestamps == true)
    }

    @Test("Whisper keeps both")
    func whisperKeepsBoth() async throws {
        let received = try await run(
            engine: .whisperKit,
            capabilities: .whisperKitDefaults,
            model: "openai_whisper-tiny",
            options: TranscriptionOptions(language: "it", wordTimestamps: true, initialPrompt: "Parola")
        )

        #expect(received?.initialPrompt == "Parola")
        #expect(received?.wordTimestamps == true)
    }
}
