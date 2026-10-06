import Foundation
import Testing
import Clocks
@testable import ParolaCore
import ParolaTestSupport

@Suite("Model store policy and download coordination")
struct ModelStorePolicyTests {
    private func makeConfig(_ managed: [String: Any]) -> ManagedConfiguration {
        let storage = temporaryDefaults("parola-store-policy-")
        storage.set(managed, forKey: "com.apple.configuration.managed")
        return ManagedConfiguration(storage: storage)
    }

    private func makeStore(_ managed: [String: Any] = [:]) -> ModelStore {
        ModelStore(
            modelsDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("store-policy-tests-\(UUID().uuidString)"),
            managedConfiguration: makeConfig(managed)
        )
    }

    @Test("download throws when downloads are disabled by policy")
    func downloadBlockedByPolicy() async {
        let store = makeStore(["disableModelDownloads": true])
        await #expect(throws: ParolaError.self) {
            _ = try await store.download(variant: "openai_whisper-tiny")
        }
    }

    @Test("an installed model is returned even when downloads are disabled")
    func installedModelSurvivesPolicy() async throws {
        let store = makeStore(["disableModelDownloads": true])
        try store.seedInstalledModel("openai_whisper-tiny")
        let url = try await store.download(variant: "openai_whisper-tiny")
        #expect(url == store.installedURL(for: "openai_whisper-tiny"))
    }

    @Test("checkDownloadsAllowed refuses with the same policyRestricted error download gives")
    func downloadsAllowedFollowsPolicy() async {
        let store = makeStore(["disableModelDownloads": true])
        var direct: ParolaError?
        do {
            try store.checkDownloadsAllowed()
        } catch {
            direct = error as? ParolaError
        }
        var viaDownload: ParolaError?
        do {
            _ = try await store.download(variant: "openai_whisper-tiny")
        } catch {
            viaDownload = error as? ParolaError
        }

        guard case .policyRestricted(let detail)? = direct else {
            Issue.record("expected policyRestricted, got \(String(describing: direct))")
            return
        }
        guard case .policyRestricted(let downloadDetail)? = viaDownload else {
            Issue.record("expected policyRestricted from download, got \(String(describing: viaDownload))")
            return
        }
        #expect(detail == downloadDetail)
    }

    @Test("checkDownloadsAllowed passes when only the engine allowlist is managed, or nothing is")
    func downloadsAllowedIgnoresEngineAllowlist() throws {
        try makeStore(["allowedEngines": [String]()]).checkDownloadsAllowed()
        try makeStore(["allowedEngines": ["parakeet"]]).checkDownloadsAllowed()
        try makeStore(["disableModelDownloads": false]).checkDownloadsAllowed()
        try makeStore().checkDownloadsAllowed()
    }

    @Test("download throws for an engine outside the allowlist")
    func downloadBlockedByAllowlist() async {
        let store = makeStore(["allowedEngines": ["whisperkit"]])
        do {
            _ = try await store.download(variant: "nvidia_parakeet-tdt-0.6b-v2")
            Issue.record("expected policyRestricted")
        } catch let error as ParolaError {
            guard case .policyRestricted = error else {
                Issue.record("expected policyRestricted, got \(error)")
                return
            }
        } catch {
            Issue.record("expected ParolaError, got \(error)")
        }
    }

    @Test("download rejects a near-miss model id with a suggestion before touching the network")
    func downloadSuggestsForTypo() async {
        let store = makeStore()
        do {
            _ = try await store.download(variant: "parakeet-tdt-0.6b-v2")
            Issue.record("expected unknownModel")
        } catch let error as ParolaError {
            guard case .unknownModel(let name, let suggestion) = error else {
                Issue.record("expected unknownModel, got \(error)")
                return
            }
            #expect(name == "parakeet-tdt-0.6b-v2")
            #expect(suggestion == "nvidia_parakeet-tdt-0.6b-v2")
        } catch {
            Issue.record("expected ParolaError, got \(error)")
        }
    }

    private actor ConcurrencyGauge {
        private(set) var current = 0
        private(set) var peak = 0
        private(set) var invocations = 0

        func enter() {
            current += 1
            invocations += 1
            peak = max(peak, current)
        }

        func exit() { current -= 1 }
    }

    @Test("concurrent downloads of the same variant are serialized and coalesced")
    func concurrentDownloadsSerialized() async throws {
        let store = makeStore()
        let gauge = ConcurrencyGauge()
        let registry = EngineRegistry()
        await registry.register(
            engineID: .whisperKit,
            capabilities: .whisperKitDefaults,
            factory: { store in WhisperKitTranscriber(modelStore: store) },
            downloader: { variant, store, _ in
                await gauge.enter()
                try await Task.sleep(for: .milliseconds(50))
                await gauge.exit()
                let url = store.installedURL(for: variant)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try Data("weights".utf8).write(to: url.appendingPathComponent("model.bin"))
                return url
            }
        )

        try await withThrowingTaskGroup(of: URL.self) { group in
            for _ in 0..<3 {
                group.addTask {
                    try await store.download(variant: "openai_whisper-tiny", registry: registry)
                }
            }
            for try await _ in group {}
        }

        #expect(await gauge.peak == 1)
        #expect(await gauge.invocations == 1, "later callers should hit the installed fast path")
        #expect(store.isInstalled("openai_whisper-tiny"))
    }
}

@Suite("Transcription session policy")
struct TranscriptionSessionPolicyTests {
    private func makeConfig(_ managed: [String: Any]) -> ManagedConfiguration {
        let storage = temporaryDefaults("parola-session-policy-")
        storage.set(managed, forKey: "com.apple.configuration.managed")
        return ManagedConfiguration(storage: storage)
    }

    private func makeSession(_ managed: [String: Any]) -> TranscriptionSession {
        TranscriptionSession(
            modelStore: ModelStore(
                modelsDirectory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("session-policy-tests-\(UUID().uuidString)")
            ),
            registry: EngineRegistry(),
            managedConfiguration: makeConfig(managed)
        )
    }

    private func expectPolicyRestricted(
        _ session: TranscriptionSession,
        options: TranscriptionOptions
    ) async {
        do {
            _ = try await session.transcribe(
                source: FileAudioSource(url: URL(fileURLWithPath: "/nonexistent.wav")),
                options: options
            )
            Issue.record("expected policyRestricted")
        } catch let error as ParolaError {
            guard case .policyRestricted = error else {
                Issue.record("expected policyRestricted, got \(error)")
                return
            }
        } catch {
            Issue.record("expected ParolaError, got \(error)")
        }
    }

    @Test("a non-English language is rejected when policy requires English")
    func englishOnlyRejectsOtherLanguages() async {
        let session = makeSession(["requireEnglishOnly": true])
        await expectPolicyRestricted(
            session,
            options: TranscriptionOptions(model: "openai_whisper-tiny", language: "it")
        )
    }

    @Test("a model whose engine is outside the allowlist is rejected")
    func allowlistRejectsOtherEngines() async {
        let session = makeSession(["allowedEngines": ["parakeet"]])
        await expectPolicyRestricted(
            session,
            options: TranscriptionOptions(model: "openai_whisper-tiny")
        )
    }

    @Test("nil model with a translate request resolves to a Whisper default")
    func translateDefaultFallsBackToWhisper() async throws {
        guard ModelCatalog.variant(id: "apple-speech-analyzer") != nil else { return }
        let registry = EngineRegistry()
        let response = MockTranscriberResponse(
            segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "ok")],
            language: "en",
            modelName: "mock-whisper"
        )
        await registry.register(
            engineID: .whisperKit,
            capabilities: .whisperKitDefaults
        ) { _ in MockTranscriber.make(response: response, clock: ImmediateClock()) }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-default-fallback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ModelStore(modelsDirectory: dir)
        try store.seedInstalledModel(ModelCatalog.fallbackModelID)
        let audioURL = dir.appendingPathComponent("input.wav")
        try Data("RIFFstub".utf8).write(to: audioURL)

        let session = TranscriptionSession(
            modelStore: store,
            registry: registry,
            managedConfiguration: makeConfig(["defaultModel": "apple-speech-analyzer"])
        )
        let transcript = try await session.transcribe(
            source: FileAudioSource(url: audioURL),
            options: TranscriptionOptions(task: .translate)
        )
        await session.unloadModel()

        #expect(transcript.modelName == "mock-whisper")
    }
}
