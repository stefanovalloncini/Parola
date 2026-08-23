import Foundation
import Testing
import Clocks
@testable import ParolaCore

@Suite("Transcribe stage reporting")
struct TranscribeStageTests {

    private enum Event: Equatable {
        case stage(TranscribeStage)
        case partial(String)
    }

    @Test("stages bracket the partial stream, ordered and once each")
    func stagesBracketPartials() async throws {
        let response = MockTranscriberResponse(
            segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "hello")],
            partials: ["hel", "hello"],
            durationSeconds: 1
        )
        let mock = MockTranscriber.make(response: response, clock: ImmediateClock())

        let events = LockedEvents()
        _ = try await mock.transcribe(
            url: URL(fileURLWithPath: "/tmp/stage-input.wav"),
            options: .default,
            handlers: TranscribeHandlers(
                onPartial: { text in events.append(.partial(text)) },
                onStage: { stage in events.append(.stage(stage)) }
            )
        )

        #expect(events.value == [
            .stage(.preparingAudio),
            .stage(.transcribing),
            .partial("hel"),
            .partial("hello"),
        ])
    }

    @Test("a response with no partials still reports both stages in order")
    func stagesWithoutPartials() async throws {
        let response = MockTranscriberResponse(
            segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "ok")],
            durationSeconds: 1
        )
        let mock = MockTranscriber.make(response: response, clock: ImmediateClock())

        let events = LockedEvents()
        _ = try await mock.transcribe(
            url: URL(fileURLWithPath: "/tmp/stage-input.wav"),
            options: .default,
            handlers: TranscribeHandlers(onStage: { stage in events.append(.stage(stage)) })
        )

        #expect(events.value == [.stage(.preparingAudio), .stage(.transcribing)])
    }

    @Test("a nil stage handler changes nothing about the transcript")
    func nilStageHandlerIsInert() async throws {
        let response = MockTranscriberResponse(
            segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "quiet")],
            durationSeconds: 1
        )
        let mock = MockTranscriber.make(response: response, clock: ImmediateClock())

        let transcript = try await mock.transcribe(
            url: URL(fileURLWithPath: "/tmp/stage-input.wav"),
            options: .default,
            handlers: TranscribeHandlers()
        )

        #expect(transcript.segments.map(\.text) == ["quiet"])
    }

    @Test("TranscriptionSession forwards the stage handler to the engine")
    func sessionForwardsStageHandler() async throws {
        let registry = EngineRegistry()
        let response = MockTranscriberResponse(
            segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "ok")],
            partials: ["ok"],
            durationSeconds: 1,
            modelName: "openai_whisper-tiny"
        )
        await registry.register(
            engineID: .whisperKit,
            capabilities: .whisperKitDefaults
        ) { _ in MockTranscriber.make(response: response, clock: ImmediateClock()) }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-stage-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ModelStore(modelsDirectory: dir)
        try store.seedInstalledModel("openai_whisper-tiny")
        let audioURL = dir.appendingPathComponent("input.wav")
        try Data("RIFFstub".utf8).write(to: audioURL)
        let session = TranscriptionSession(modelStore: store, registry: registry)

        let events = LockedEvents()
        _ = try await session.transcribe(
            source: FileAudioSource(url: audioURL),
            options: TranscriptionOptions(model: "openai_whisper-tiny"),
            stageHandler: { stage in events.append(.stage(stage)) }
        )
        await session.unloadModel()

        #expect(events.value == [.stage(.preparingAudio), .stage(.transcribing)])
    }

    private final class LockedEvents: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [Event] = []
        func append(_ event: Event) {
            lock.lock(); defer { lock.unlock() }
            events.append(event)
        }
        var value: [Event] {
            lock.lock(); defer { lock.unlock() }
            return events
        }
    }
}
