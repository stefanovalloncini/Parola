import Foundation
import Testing
@testable import ParolaCore

@Suite("Capability guards")
struct CapabilityGuardTests {
    actor StubWhisperTranscriber: Transcriber {
        static let engineID = EngineID.whisperKit
        static let capabilities = EngineCapabilities.whisperKitDefaults
        func load(model: String) async throws {}
        func transcribe(url: URL, options: TranscriptionOptions) async throws -> Transcript {
            Transcript(segments: [], language: "en", modelName: "stub", sourceURL: url)
        }
        func unload() async {}
        func loadedModelName() async -> String? { nil }
    }

    actor StubParakeetTranscriber: Transcriber {
        static let engineID = EngineID.parakeet
        static let capabilities = EngineCapabilities.parakeetDefaults
        func load(model: String) async throws {}
        func transcribe(url: URL, options: TranscriptionOptions) async throws -> Transcript {
            Transcript(segments: [], language: "en", modelName: "stub", sourceURL: url)
        }
        func unload() async {}
        func loadedModelName() async -> String? { nil }
    }

    struct DummyAudioSource: AudioSource {
        let url: URL
        func prepare() async throws -> URL { url }
        func cancel() async {}
    }

    private func makeSession() async -> TranscriptionSession {
        let registry = EngineRegistry()
        await registry.register(
            engineID: StubWhisperTranscriber.engineID,
            capabilities: StubWhisperTranscriber.capabilities
        ) { _ in StubWhisperTranscriber() }
        await registry.register(
            engineID: StubParakeetTranscriber.engineID,
            capabilities: StubParakeetTranscriber.capabilities
        ) { _ in StubParakeetTranscriber() }

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-guard-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let store = ModelStore(modelsDirectory: tmpDir)
        return TranscriptionSession(modelStore: store, registry: registry, idleTimeout: 1)
    }

    @Test("Parakeet rejects Italian before attempting any download")
    func parakeetRejectsItalian() async throws {
        let session = await makeSession()
        let audio = DummyAudioSource(url: FileManager.default.temporaryDirectory.appendingPathComponent("none.wav"))

        var thrown: ParolaError?
        do {
            _ = try await session.transcribe(
                source: audio,
                options: TranscriptionOptions(model: "nvidia_parakeet-tdt-0.6b-v2", language: "it")
            )
        } catch let e as ParolaError {
            thrown = e
        }
        switch thrown {
        case .unsupportedForEngine: break
        default: Issue.record("expected unsupportedForEngine, got \(String(describing: thrown))")
        }
    }

    @Test("Parakeet rejects translate task")
    func parakeetRejectsTranslate() async throws {
        let session = await makeSession()
        let audio = DummyAudioSource(url: FileManager.default.temporaryDirectory.appendingPathComponent("none.wav"))

        var thrown: ParolaError?
        do {
            _ = try await session.transcribe(
                source: audio,
                options: TranscriptionOptions(
                    model: "nvidia_parakeet-tdt-0.6b-v2",
                    language: "en",
                    task: .translate
                )
            )
        } catch let e as ParolaError {
            thrown = e
        }
        switch thrown {
        case .unsupportedForEngine: break
        default: Issue.record("expected unsupportedForEngine, got \(String(describing: thrown))")
        }
    }

    @Test("English-only engine accepts language=en explicitly")
    func englishOnlyAcceptsEnglish() async {
        let caps = EngineCapabilities.parakeetDefaults
        #expect(caps.supportedLanguages.allows("en"))
    }

    @Test("Multilingual Whisper accepts auto-detect (language nil)")
    func whisperAutoDetect() async {
        let caps = EngineCapabilities.whisperKitDefaults
        #expect(caps.supportedLanguages.allows(nil))
    }

    @Test("static catalog capabilities gate language by model id, matching the warning logic")
    func staticCatalogCapabilitiesGateLanguage() {
        let parakeet = ModelCatalog.staticCapabilities(forID: "nvidia_parakeet-tdt-0.6b-v2")?.supportedLanguages
        #expect(parakeet?.allows("it") == false)
        #expect(parakeet?.allows("en") == true)
        #expect(parakeet?.allows(nil) == false)

        let whisper = ModelCatalog.staticCapabilities(forID: "openai_whisper-large-v3_turbo")?.supportedLanguages
        #expect(whisper?.allows("it") == true)
    }
}
