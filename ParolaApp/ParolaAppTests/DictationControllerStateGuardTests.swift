import AppKit
import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaDictation

private final class QuietHotkeyMonitorBox: HotkeyMonitor {
    func start(handler: @escaping @Sendable (HotkeyEvent) -> Void) async {}
    func stop() async {}
}

/// `stopAndTranscribe` parks until released, standing in for a slow flush
/// (transcription + LLM cleanup) of a session the controller already dropped.
private actor SlowFlushRecorder: DictationRecorder {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func start() async throws {}

    func stopAndTranscribe() async throws -> String {
        await withCheckedContinuation { continuation in
            if released {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
        return ""
    }

    func stopAndDiscard() async {}

    func release() {
        released = true
        let due = waiters
        waiters = []
        for waiter in due { waiter.resume() }
    }
}

private struct IdentityPostProcessor: TextPostProcessor {
    func process(_ text: String) async -> String { text }
}

@MainActor
@Suite("Dictation controller state guards")
struct DictationControllerStateGuardTests {
    private func makeConfiguration() -> DictationController.Configuration {
        DictationController.Configuration(
            pipeline: DictationPipelineConfiguration(
                modelName: "openai_whisper-tiny", streamingEnabled: false, postProcessor: IdentityPostProcessor()
            ),
            hotkeyKeyCode: 96,
            mode: .toggle
        )
    }

    private func poll(
        budget: Duration = .seconds(5),
        until condition: @MainActor () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + budget
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    @Test("a replaced coordinator's late state cannot overwrite the live session")
    func staleCoordinatorStateIsIgnored() async {
        let controller = DictationController()
        let slowRecorder = SlowFlushRecorder()
        var recorders: [any DictationRecorder] = [slowRecorder, SlowFlushRecorder()]
        controller.hotkeyFactory = { _, _ in QuietHotkeyMonitorBox() }
        controller.recorderFactory = { _ in recorders.removeFirst() }

        controller.start(configuration: makeConfiguration())
        controller.simulatePress()
        let firstListening = await poll { controller.state == .listening }
        #expect(firstListening, "the first session should reach listening")

        // Restart: the old coordinator's flush parks in SlowFlushRecorder while the
        // new session starts listening (simulatePress bypasses the monitor queue).
        controller.stop()
        controller.start(configuration: makeConfiguration())
        controller.simulatePress()
        let secondListening = await poll { controller.state == .listening }
        #expect(secondListening, "the second session should reach listening")

        await slowRecorder.release()
        await controller.monitorWork?.value
        try? await Task.sleep(for: .milliseconds(100))

        #expect(
            controller.state == .listening,
            "the old coordinator's trailing .idle must not stomp the live session's state"
        )

        controller.abort()
    }

    @Test("download progress after stop does not resurrect dictation UI state")
    func downloadProgressAfterStopIsIgnored() async {
        let controller = DictationController()
        controller.hotkeyFactory = { _, _ in QuietHotkeyMonitorBox() }
        controller.recorderFactory = { _ in SlowFlushRecorder() }

        controller.start(configuration: makeConfiguration())
        controller.stop()

        controller.noteModelDownloadProgress(0.5)
        #expect(
            controller.modelDownloadProgress == nil,
            "a stray download callback after stop must not bring the HUD state back"
        )
    }
}
