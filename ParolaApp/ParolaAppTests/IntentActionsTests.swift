import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Intent actions")
struct IntentActionsTests {

    private func makeModel() -> AppModel {
        AppModel(
            skipBootstrap: true,
            defaults: temporaryDefaults(),
            libraryURL: makeTempLibraryURL("intent-actions")
        )
    }

    @Test("transcribe-file intent throws while recording")
    func transcribeThrowsWhileRecording() async {
        let model = makeModel()
        model.phase = .recording(source: .microphone)
        await #expect(throws: IntentActionError.recordingInProgress) {
            _ = try await model.transcribeFileFromIntent(URL(fileURLWithPath: "/tmp/a.wav"))
        }
    }

    @Test("transcribe-file intent throws while a batch is running")
    func transcribeThrowsWhileBatchRunning() async throws {
        let model = makeModel()
        model.startBatch(urls: [URL(fileURLWithPath: "/tmp/a.wav")])
        await model.handleBatchEvent(.started(jobID: model.batchJobs[0].id))
        await #expect(throws: IntentActionError.batchInProgress) {
            _ = try await model.transcribeFileFromIntent(URL(fileURLWithPath: "/tmp/b.wav"))
        }
    }

    @Test("transcribe-file intent rejects subtitle and project files")
    func transcribeRejectsNonMedia() async {
        let model = makeModel()
        await #expect(throws: IntentActionError.self) {
            _ = try await model.transcribeFileFromIntent(URL(fileURLWithPath: "/tmp/subs.srt"))
        }
        await #expect(throws: IntentActionError.self) {
            _ = try await model.transcribeFileFromIntent(URL(fileURLWithPath: "/tmp/doc.parola"))
        }
    }

    @Test("stop-recording intent throws when nothing is recording")
    func stopThrowsWhenIdle() async {
        let model = makeModel()
        await #expect(throws: IntentActionError.notRecording) {
            _ = try await model.stopRecordingFromIntent()
        }
    }

    @Test("stop-recording intent throws when the recording phase has no capture behind it")
    func stopThrowsOnStalePhase() async {
        let model = makeModel()
        model.phase = .recording(source: .microphone)
        await #expect(throws: IntentActionError.notRecording) {
            _ = try await model.stopRecordingFromIntent()
        }
    }

    @Test("a recording outcome waiter gets the transcript text when streaming finishes", .timeLimit(.minutes(1)))
    func waiterReceivesStreamingFinish() async throws {
        let model = makeModel()
        let waiter = Task { try await model.awaitRecordingOutcome() }
        while model.recordingOutcomeWaiters.isEmpty { await Task.yield() }

        let final = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "done words")],
            language: "en",
            modelName: "mock"
        )
        await model.handleStreamingEvent(.finished(final))

        let text = try await waiter.value
        #expect(text == "done words")
    }

    @Test("a streaming failure rejects pending waiters with the failure message", .timeLimit(.minutes(1)))
    func waiterReceivesStreamingFailure() async throws {
        let model = makeModel()
        let waiter = Task { try await model.awaitRecordingOutcome() }
        while model.recordingOutcomeWaiters.isEmpty { await Task.yield() }

        await model.handleStreamingEvent(.failed("mic died"))

        await #expect(throws: IntentActionError.failed("mic died")) {
            _ = try await waiter.value
        }
    }

    @Test("cancelling current work rejects pending waiters", .timeLimit(.minutes(1)))
    func waiterRejectedOnCancel() async throws {
        let model = makeModel()
        let waiter = Task { try await model.awaitRecordingOutcome() }
        while model.recordingOutcomeWaiters.isEmpty { await Task.yield() }

        model.cancelCurrentWork()

        await #expect(throws: IntentActionError.cancelled) {
            _ = try await waiter.value
        }
    }

    @Test("registerIntentPerformers installs both hooks")
    func registrationInstallsHooks() async throws {
        defer {
            IntentPerformers.stopRecording = nil
            IntentPerformers.transcribeFile = nil
        }
        let model = makeModel()
        model.registerIntentPerformers()

        #expect(IntentPerformers.stopRecording != nil)
        #expect(IntentPerformers.transcribeFile != nil)
        await #expect(throws: IntentActionError.notRecording) {
            _ = try await IntentPerformers.stopRecording?()
        }
    }
}
