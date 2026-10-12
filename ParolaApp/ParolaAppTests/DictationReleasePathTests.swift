import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaDictation

private final class ResolverProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }
    func resolve() async -> DictationWorkflow? {
        lock.withLock { count += 1 }
        return nil
    }
}

private final class InsertClock: TextInserter, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    var texts: [String] { lock.withLock { items } }
    let resolve: @Sendable () async -> DictationWorkflow?
    init(resolve: @escaping @Sendable () async -> DictationWorkflow?) { self.resolve = resolve }
    func insert(_ text: String) async throws {
        _ = await resolve()
        lock.withLock { items.append(text) }
    }
}

private final class ConfirmingSession: StreamingTranscriber, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<StreamingEvent>.Continuation?
    func start(
        options: TranscriptionOptions,
        speakerLabeler: (any StreamingSpeakerLabeler)?,
        downloadProgress: (@Sendable (Double) -> Void)?
    ) async throws -> AsyncStream<StreamingEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: StreamingEvent.self)
        lock.withLock { self.continuation = continuation }
        continuation.yield(.confirmed(TranscriptSegment(id: 0, start: 0, end: 1, text: "hello")))
        return stream
    }
    func stop() async { lock.withLock { continuation }?.finish() }
    func cancel() async { lock.withLock { continuation }?.finish() }
    func currentModel() async -> String? { nil }
}

@MainActor
@Suite("Dictation release path")
struct DictationReleasePathTests {
    private func release(
        streaming: Bool, probe: ResolverProbe
    ) async throws -> (atRelease: Int, resolutions: Int, text: [String]) {
        let resolver: @Sendable () async -> DictationWorkflow? = { await probe.resolve() }
        let recorder = MicDictationRecorder(
            model: streaming ? "openai_whisper-large-v3_turbo" : nil,
            language: nil,
            streamingEnabled: streaming,
            session: TranscriptionSession(),
            workflowResolver: resolver,
            makeStreamingSession: { ConfirmingSession() },
            warmFallbackModel: { _ in }
        )
        let inserter = InsertClock(resolve: resolver)
        let coordinator = DictationCoordinator(
            hotkey: SilentHotkeyMonitor(), recorder: recorder, inserter: inserter,
            mode: .pushToTalk, features: .all
        )
        await coordinator.simulatePress()
        let atRelease = probe.calls
        await coordinator.simulateRelease()
        return (atRelease, probe.calls, inserter.texts)
    }

    @Test("streaming release resolves the workflow only for insertion")
    func streamingResolutions() async throws {
        let probe = ResolverProbe()
        let out = try await release(streaming: true, probe: probe)
        #expect(out.text == ["hello"])
        #expect(out.atRelease == 1)
        #expect(out.resolutions == 2)
    }

    @Test("fallback release resolves the workflow only for insertion")
    func fallbackResolutions() async throws {
        let audio = try makeTakeWAV("release-path", seconds: 0.3)
        defer { try? FileManager.default.removeItem(at: audio) }
        try await withMocksCleared([.audioSource, .transcriber]) {
            await MockAudioSourceRegistry.shared.install(kind: .mic, fixtureURL: audio)
            await MockTranscriberRegistry.shared.install(
                engineID: nil,
                response: MockTranscriberResponse(segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "hello")])
            )
            let probe = ResolverProbe()
            let out = try await release(streaming: false, probe: probe)
            #expect(out.text.first?.contains("hello") == true)
            #expect(out.atRelease == 1)
            #expect(out.resolutions == 2)
        }
    }
}
