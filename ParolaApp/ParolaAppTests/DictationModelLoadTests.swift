import Foundation
import os
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Dictation while the model loads", .serialized)
struct DictationModelLoadTests {
    private func makeRecorder(
        gate: MockTranscriberGate, log: MockTranscriberLog, loading: OSAllocatedUnfairLock<Bool>
    ) -> MicDictationRecorder {
        let response = MockTranscriberResponse(downloadFractions: [0.1], gate: gate, waitsForModelOnStop: true, log: log)
        return MicDictationRecorder(
            model: "openai_whisper-large-v3_turbo",
            language: nil,
            streamingEnabled: true,
            downloadProgress: { _ in loading.withLock { $0 = true } },
            makeStreamingSession: { MockStreamingTranscriber(response: response, clock: ContinuousClock()) },
            warmFallbackModel: { _ in }
        )
    }

    @Test("a discard during the model load cancels the session at once", .timeLimit(.minutes(1)))
    func discardDuringLoadReachesTheSession() async throws {
        let log = MockTranscriberLog()
        let loading = OSAllocatedUnfairLock(initialState: false)
        let recorder = makeRecorder(gate: MockTranscriberGate(), log: log, loading: loading)
        let starting = Task { try await recorder.start() }
        await waitUntil { loading.withLock { $0 } }

        await recorder.stopAndDiscard()

        await waitUntil { await log.endings == ["cancel"] }
        await #expect(throws: CancellationError.self) { try await starting.value }
    }

    @Test("a discard before the session exists keeps the mic off for the whole start", .timeLimit(.minutes(1)))
    func discardBeforeTheSessionExists() async throws {
        let resolving = OSAllocatedUnfairLock(initialState: false)
        let (released, release) = AsyncStream<Void>.makeStream()
        let made = OSAllocatedUnfairLock(initialState: 0)
        let recorder = MicDictationRecorder(
            model: "openai_whisper-large-v3_turbo",
            language: nil,
            streamingEnabled: true,
            workflowResolver: { _ in
                resolving.withLock { $0 = true }
                for await _ in released {}
                return nil
            },
            makeStreamingSession: {
                made.withLock { $0 += 1 }
                return MockStreamingTranscriber(response: MockTranscriberResponse(), clock: ContinuousClock())
            },
            warmFallbackModel: { _ in }
        )
        let starting = Task { try await recorder.start() }
        await waitUntil { resolving.withLock { $0 } }

        await recorder.stopAndDiscard()
        release.finish()

        await #expect(throws: CancellationError.self) { try await starting.value }
        #expect(made.withLock { $0 } == 0)
    }
}
