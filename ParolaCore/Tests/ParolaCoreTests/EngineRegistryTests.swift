import Foundation
import Testing
@testable import ParolaCore

@Suite("Engine registry + capabilities")
struct EngineRegistryTests {
    actor StubTranscriber: Transcriber {
        static let engineID = EngineID("stub")
        static let capabilities = EngineCapabilities(
            supportedLanguages: .all,
            supportsTranslate: true,
            supportsInitialPrompt: true,
            supportsWordTimestamps: true,
            supportsDiarization: false
        )
        private var loaded: String?
        func load(model: String) async throws { loaded = model }
        func transcribe(url: URL, options: TranscriptionOptions) async throws -> Transcript {
            Transcript(segments: [], language: "en", modelName: loaded ?? "?", sourceURL: url, durationSeconds: 0)
        }
        func unload() async { loaded = nil }
        func loadedModelName() async -> String? { loaded }
    }

    actor SecondStubTranscriber: Transcriber {
        static let engineID = EngineID("second")
        static let capabilities = EngineCapabilities(
            supportedLanguages: .only(["en"]),
            supportsTranslate: false,
            supportsInitialPrompt: false,
            supportsWordTimestamps: true,
            supportsDiarization: true
        )
        func load(model: String) async throws {}
        func transcribe(url: URL, options: TranscriptionOptions) async throws -> Transcript {
            Transcript(segments: [], language: "en", modelName: "?", sourceURL: url, durationSeconds: 0)
        }
        func unload() async {}
        func loadedModelName() async -> String? { nil }
    }

    private func makeStore() -> ModelStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-engine-test-\(UUID().uuidString)")
        return ModelStore(modelsDirectory: dir)
    }

    @Test("registering an engine makes it resolvable")
    func registerAndResolve() async throws {
        let registry = EngineRegistry()
        await registry.register(
            engineID: StubTranscriber.engineID,
            capabilities: StubTranscriber.capabilities
        ) { _ in StubTranscriber() }

        #expect(await registry.isRegistered(StubTranscriber.engineID))
        let t = try await registry.transcriber(for: StubTranscriber.engineID, store: makeStore())
        #expect(type(of: t).engineID == StubTranscriber.engineID)
    }

    @Test("resolving an unregistered engine throws")
    func resolveUnregisteredThrows() async throws {
        let registry = EngineRegistry()
        await #expect(throws: ParolaError.self) {
            _ = try await registry.transcriber(for: EngineID("ghost"), store: makeStore())
        }
    }

    @Test("registering two engines exposes both")
    func multipleEngines() async throws {
        let registry = EngineRegistry()
        await registry.register(
            engineID: StubTranscriber.engineID,
            capabilities: StubTranscriber.capabilities
        ) { _ in StubTranscriber() }
        await registry.register(
            engineID: SecondStubTranscriber.engineID,
            capabilities: SecondStubTranscriber.capabilities
        ) { _ in SecondStubTranscriber() }

        let ids = await registry.registeredEngines()
        #expect(ids.contains(StubTranscriber.engineID))
        #expect(ids.contains(SecondStubTranscriber.engineID))
        #expect(ids.count == 2)
    }

    @Test("English-only capabilities reject non-English language")
    func englishOnlyRejectsItalian() {
        let caps = EngineCapabilities.parakeetDefaults
        #expect(caps.supportedLanguages.allows("en"))
        #expect(caps.supportedLanguages.allows("it") == false)
        #expect(caps.supportedLanguages.allows(nil) == false)
        #expect(caps.supportedLanguages.isEnglishOnly)
    }

    @Test("supportedLanguages.all accepts any language including nil auto-detect")
    func allAcceptsEverything() {
        let caps = EngineCapabilities.whisperKitDefaults
        #expect(caps.supportedLanguages.allows("en"))
        #expect(caps.supportedLanguages.allows("it"))
        #expect(caps.supportedLanguages.allows(nil))
    }

    @Test("tightening WhisperKit defaults with an English-only variant disables translate")
    func tightenDisablesTranslate() {
        let tightened = EngineCapabilities.whisperKitDefaults.tightened(by: .only(["en"]))
        #expect(tightened.supportedLanguages.isEnglishOnly)
        #expect(tightened.supportsTranslate == false)
    }

    @Test("tightening with .all keeps engine defaults")
    func tightenWithAllNoop() {
        let tightened = EngineCapabilities.parakeetDefaults.tightened(by: nil)
        #expect(tightened == .parakeetDefaults)
    }
}
