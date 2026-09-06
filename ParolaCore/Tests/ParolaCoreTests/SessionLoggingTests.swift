import Foundation
import Testing
@testable import ParolaCore

@Suite("Transcription session logging", .serialized)
struct SessionLoggingTests {
    private actor StubTranscriber: Transcriber {
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
                segments: [
                    TranscriptSegment(id: 0, start: 0, end: 1, text: "one"),
                    TranscriptSegment(id: 1, start: 1, end: 2, text: "two"),
                ],
                language: "en",
                modelName: loaded ?? "?",
                sourceURL: url,
                durationSeconds: 2
            )
        }
    }

    private func withSink(_ body: (CapturingDiagnosticsSink) async throws -> Void) async rethrows {
        let sink = CapturingDiagnosticsSink()
        try await ParolaLog.withSink(sink) { try await body(sink) }
    }

    private func managedConfiguration(_ managed: [String: Any]) -> ManagedConfiguration {
        let storage = temporaryDefaults("parola-session-logging-")
        storage.set(managed, forKey: "com.apple.configuration.managed")
        return ManagedConfiguration(storage: storage)
    }

    private func makeSession(
        engineID: EngineID = .whisperKit,
        capabilities: EngineCapabilities = .whisperKitDefaults,
        managed: [String: Any] = [:],
        clock: any Clock<Duration> = ContinuousClock()
    ) async throws -> (session: TranscriptionSession, audioURL: URL) {
        let registry = EngineRegistry()
        await registry.register(engineID: engineID, capabilities: capabilities) { _ in
            StubTranscriber()
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-session-logging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = ModelStore(modelsDirectory: directory)
        try store.seedInstalledModel("openai_whisper-tiny")
        let audioURL = directory.appendingPathComponent("input.wav")
        try Data("RIFFstub".utf8).write(to: audioURL)
        let session = TranscriptionSession(
            modelStore: store,
            registry: registry,
            clock: clock,
            managedConfiguration: managedConfiguration(managed)
        )
        return (session, audioURL)
    }

    private func modelRecords(
        _ sink: CapturingDiagnosticsSink, message: String
    ) -> [LogRecord] {
        sink.records.filter { $0.category == .models && $0.message.rendered == message }
    }

    @Test("a run reports its start and its finish")
    func startAndFinish() async throws {
        try await withSink { sink in
            let (session, audioURL) = try await makeSession()
            let transcript = try await session.transcribe(
                source: FileAudioSource(url: audioURL),
                options: TranscriptionOptions(model: "openai_whisper-tiny")
            )
            await session.unloadModel()

            let start = try #require(
                modelRecords(sink, message: "transcribe starting on whisperkit").first
            )
            #expect(start.level == .info)
            #expect(start.fields[.model]?.text == "openai_whisper-tiny")

            let finish = try #require(modelRecords(sink, message: "transcribe finished").first)
            #expect(finish.level == .info)
            #expect(finish.fields[.model]?.text == "openai_whisper-tiny")
            #expect(finish.fields[.engine]?.text == "whisperkit")
            #expect(finish.fields[.count]?.text == String(transcript.segments.count))
            #expect(finish.fields[.elapsed] != nil)
        }
    }

    @Test("a prewarm that cannot load reports the failure it used to swallow")
    func prewarmFailure() async throws {
        try await withSink { sink in
            let (session, _) = try await makeSession(engineID: .parakeet)
            await session.prewarm(modelName: "openai_whisper-tiny")

            let record = try #require(
                modelRecords(sink, message: "prewarm failed for openai_whisper-tiny").first
            )
            #expect(record.level == .debug)
            #expect(record.fields[.error]?.text == "ParolaError.engineNotRegistered(whisperkit)")
        }
    }

    @Test("a managed English-only policy reports the language it turned down")
    func policyRejectsLanguage() async throws {
        try await withSink { sink in
            let (session, audioURL) = try await makeSession(managed: ["requireEnglishOnly": true])
            await #expect(throws: ParolaError.self) {
                _ = try await session.transcribe(
                    source: FileAudioSource(url: audioURL),
                    options: TranscriptionOptions(model: "openai_whisper-tiny", language: "it")
                )
            }
            let record = try #require(
                modelRecords(sink, message: "rejected by policy: language").first
            )
            #expect(record.level == .notice)
        }
    }

    @Test("a managed engine allowlist reports the engine it turned down")
    func policyRejectsEngine() async throws {
        try await withSink { sink in
            let (session, audioURL) = try await makeSession(
                managed: ["allowedEngines": ["parakeet"]]
            )
            await #expect(throws: ParolaError.self) {
                _ = try await session.transcribe(
                    source: FileAudioSource(url: audioURL),
                    options: TranscriptionOptions(model: "openai_whisper-tiny")
                )
            }
            let record = try #require(
                modelRecords(sink, message: "rejected by policy: engine whisperkit").first
            )
            #expect(record.level == .notice)
        }
    }

    @Test("an engine missing from the registry is reported as an error")
    func unregisteredEngine() async throws {
        try await withSink { sink in
            let (session, audioURL) = try await makeSession(engineID: .parakeet)
            await #expect(throws: ParolaError.self) {
                _ = try await session.transcribe(
                    source: FileAudioSource(url: audioURL),
                    options: TranscriptionOptions(model: "openai_whisper-tiny")
                )
            }
            let record = try #require(
                modelRecords(sink, message: "engine whisperkit is not registered").first
            )
            #expect(record.level == .error)
        }
    }

    @Test("each capability rejection reports its own axis")
    func capabilityRejections() async throws {
        let limited = EngineCapabilities(
            supportedLanguages: .only(["en"]),
            supportsTranslate: false,
            supportsInitialPrompt: true,
            supportsWordTimestamps: true,
            supportsDiarization: false
        )
        try await withSink { sink in
            let (session, audioURL) = try await makeSession(capabilities: limited)
            let source = FileAudioSource(url: audioURL)
            let rejected: [TranscriptionOptions] = [
                TranscriptionOptions(model: "openai_whisper-tiny", language: "it"),
                TranscriptionOptions(model: "openai_whisper-tiny", task: .translate),
                TranscriptionOptions(model: "openai_whisper-tiny", diarize: true),
            ]
            for options in rejected {
                await #expect(throws: ParolaError.self) {
                    _ = try await session.transcribe(source: source, options: options)
                }
            }

            let language = try #require(
                modelRecords(sink, message: "engine whisperkit rejected language").first
            )
            #expect(language.level == .notice)
            #expect(language.fields[.language]?.text == "it")
            #expect(modelRecords(sink, message: "engine whisperkit rejected translate").count == 1)
            #expect(modelRecords(sink, message: "engine whisperkit rejected diarize").count == 1)
        }
    }

    @Test("an idle unload reports the timeout it waited out")
    func idleUnload() async throws {
        try await withSink { sink in
            let clock = TestClock()
            let (session, audioURL) = try await makeSession(clock: clock)
            _ = try await session.transcribe(
                source: FileAudioSource(url: audioURL),
                options: TranscriptionOptions(model: "openai_whisper-tiny")
            )
            let armed = await poll { clock.sleeperCount == 2 }
            #expect(armed, "expected the diarizer and model idle timers")

            clock.advance(by: .seconds(600))
            let unloaded = await poll { await session.currentModel() == nil }
            #expect(unloaded, "the model should unload at the idle timeout")

            let landed = await poll {
                !modelRecords(sink, message: "model unloaded after idle").isEmpty
            }
            #expect(landed)
            let record = try #require(
                modelRecords(sink, message: "model unloaded after idle").first
            )
            #expect(record.level == .info)
            #expect(record.fields[.elapsed]?.text == "600.00")
        }
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
}
