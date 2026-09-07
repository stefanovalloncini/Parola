import Foundation
import Testing
@testable import ParolaCore

@Suite("English-only model on auto language")
struct EnglishOnlyAutoLanguageTests {
    private actor RecordingTranscriber: Transcriber {
        static let engineID = EngineID.parakeet
        static let capabilities = EngineCapabilities.parakeetDefaults
        private(set) var receivedLanguage: String?
        private(set) var ran = false

        func load(model: String) async throws {}
        func transcribe(url: URL, options: TranscriptionOptions, handlers: TranscribeHandlers) async throws -> Transcript {
            ran = true
            receivedLanguage = options.language
            return Transcript(segments: [], language: "en", modelName: "stub", sourceURL: url)
        }
        func unload() async {}
        func loadedModelName() async -> String? { nil }
    }

    private func makeSession(engineID: EngineID, transcriber: RecordingTranscriber, modelID: String) async throws -> TranscriptionSession {
        let registry = EngineRegistry()
        await registry.register(
            engineID: engineID,
            capabilities: ModelCatalog.staticCapabilities(forID: modelID) ?? .whisperKitDefaults
        ) { _ in transcriber }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-english-only-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ModelStore(modelsDirectory: dir)
        try store.seedInstalledModel(modelID)
        return TranscriptionSession(modelStore: store, registry: registry)
    }

    @Test("an English-only model on auto language is pinned to English before the engine runs")
    func pinsToEnglish() async throws {
        let transcriber = RecordingTranscriber()
        let modelID = "nvidia_parakeet-tdt-0.6b-v2"
        let session = try await makeSession(engineID: .parakeet, transcriber: transcriber, modelID: modelID)
        let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent("input-\(UUID().uuidString).wav")
        try Data("RIFFstub".utf8).write(to: audioURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        _ = try await session.transcribe(
            source: FileAudioSource(url: audioURL),
            options: TranscriptionOptions(model: modelID, language: nil)
        )
        await session.unloadModel()

        #expect(await transcriber.ran)
        #expect(await transcriber.receivedLanguage == "en")
    }

    @Test("a multilingual model on auto language is left alone")
    func leavesMultilingualAlone() async throws {
        let transcriber = RecordingTranscriber()
        let modelID = "openai_whisper-large-v3_turbo"
        let session = try await makeSession(engineID: .whisperKit, transcriber: transcriber, modelID: modelID)
        let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent("input-\(UUID().uuidString).wav")
        try Data("RIFFstub".utf8).write(to: audioURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        _ = try await session.transcribe(
            source: FileAudioSource(url: audioURL),
            options: TranscriptionOptions(model: modelID, language: nil)
        )
        await session.unloadModel()

        #expect(await transcriber.ran)
        #expect(await transcriber.receivedLanguage == nil)
    }

    @Test("an explicit language request is never overridden")
    func explicitLanguageSurvives() async throws {
        let transcriber = RecordingTranscriber()
        let modelID = "nvidia_parakeet-tdt-0.6b-v2"
        let session = try await makeSession(engineID: .parakeet, transcriber: transcriber, modelID: modelID)
        let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent("input-\(UUID().uuidString).wav")
        try Data("RIFFstub".utf8).write(to: audioURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        _ = try await session.transcribe(
            source: FileAudioSource(url: audioURL),
            options: TranscriptionOptions(model: modelID, language: "en")
        )
        await session.unloadModel()

        #expect(await transcriber.receivedLanguage == "en")
    }
}
