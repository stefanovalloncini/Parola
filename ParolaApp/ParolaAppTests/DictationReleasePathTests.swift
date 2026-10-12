import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaDictation

private final class ResolverProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let cost: Duration
    init(cost: Duration) { self.cost = cost }
    var calls: Int { lock.withLock { count } }
    func resolve() async -> DictationWorkflow? {
        lock.withLock { count += 1 }
        try? await Task.sleep(for: cost)
        return nil
    }
}

private final class InsertClock: TextInserter, @unchecked Sendable {
    private let lock = NSLock()
    private var instant: ContinuousClock.Instant?
    private(set) var texts: [String] = []
    let resolve: @Sendable () async -> DictationWorkflow?
    init(resolve: @escaping @Sendable () async -> DictationWorkflow?) { self.resolve = resolve }
    var insertedAt: ContinuousClock.Instant? { lock.withLock { instant } }
    func insert(_ text: String) async throws {
        _ = await resolve()
        lock.withLock { instant = .now; texts.append(text) }
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
    ) async throws -> (latency: Duration, resolutions: Int, text: [String]) {
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
        try await Task.sleep(for: .milliseconds(100))
        let released = ContinuousClock.now
        await coordinator.simulateRelease()
        let at = try #require(inserter.insertedAt)
        return (released.duration(to: at), probe.calls, inserter.texts)
    }

    @Test("streaming release resolves the workflow only for insertion")
    func streamingResolutions() async throws {
        let probe = ResolverProbe(cost: .milliseconds(40))
        let out = try await release(streaming: true, probe: probe)
        print("RELEASE streaming latency=\(out.latency) resolutions=\(out.resolutions)")
        #expect(out.text == ["hello"])
        #expect(out.resolutions == 2)
        #expect(out.latency < .milliseconds(80))
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
            let probe = ResolverProbe(cost: .milliseconds(40))
            let out = try await release(streaming: false, probe: probe)
            print("RELEASE fallback latency=\(out.latency) resolutions=\(out.resolutions)")
            #expect(out.text.first?.contains("hello") == true)
            #expect(out.resolutions == 2)
            #expect(out.latency < .milliseconds(80))
        }
    }
}
