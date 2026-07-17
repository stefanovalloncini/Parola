import Foundation
import Testing
@testable import ParolaCore

private final class GatedModelState: @unchecked Sendable {
    private let lock = NSLock()
    private var _released = false
    private var _terminated = false
    private var _streamClosed = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func release() {
        lock.lock()
        _released = true
        let due = waiters
        waiters = []
        lock.unlock()
        for waiter in due { waiter.resume() }
    }

    func waitForRelease() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if _released {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    var terminated: Bool {
        lock.lock(); defer { lock.unlock() }
        return _terminated
    }

    func markTerminated() {
        lock.lock()
        _terminated = true
        _streamClosed = true
        lock.unlock()
    }

    var streamClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return _streamClosed
    }

    func markStreamClosed() {
        lock.lock()
        _streamClosed = true
        lock.unlock()
    }
}

private struct GatedLanguageModel: LanguageModel {
    let state: GatedModelState

    func respond(history: [ChatTurn]) async throws -> String {
        await state.waitForRelease()
        return "Late answer"
    }

    func stream(history: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
        let state = state
        return AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield("Hello")
                await state.waitForRelease()
                continuation.yield(" world")
                state.markStreamClosed()
                continuation.finish()
            }
            continuation.onTermination = { reason in
                if case .cancelled = reason {
                    state.markTerminated()
                }
                task.cancel()
            }
        }
    }
}

@Suite("Transcript chat cancellation")
struct TranscriptChatCancellationTests {
    private func makeTranscript() -> Transcript {
        Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "Hello world.")],
            language: "en",
            modelName: "tiny"
        )
    }

    private func poll(
        budget: Duration = .seconds(5),
        until condition: @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + budget
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }

    @Test("cancelling the stream consumer reaches the model and appends nothing to history")
    func streamCancellationPropagates() async throws {
        let state = GatedModelState()
        let chat = TranscriptChatSession(
            transcript: makeTranscript(),
            model: GatedLanguageModel(state: state)
        )

        let firstDelta = LockedProbe()
        let consumer = Task {
            for try await event in chat.stream("Q") {
                if case .delta = event { firstDelta.mark() }
            }
        }
        let deltaArrived = await poll { firstDelta.isMarked }
        #expect(deltaArrived, "the first delta should reach the consumer")

        consumer.cancel()
        state.release()

        let closed = await poll { state.streamClosed }
        #expect(closed, "the model stream should wind down after cancellation")
        let modelCancelled = await poll(budget: .seconds(2)) { state.terminated }
        #expect(modelCancelled, "cancellation must propagate into the model's stream")

        try? await Task.sleep(for: .milliseconds(300))
        let history = await chat.history
        #expect(history.isEmpty, "a cancelled generation must not be recorded in history")
    }

    @Test("cancelling ask surfaces CancellationError and appends nothing to history")
    func askCancellationPropagates() async throws {
        let state = GatedModelState()
        let chat = TranscriptChatSession(
            transcript: makeTranscript(),
            model: GatedLanguageModel(state: state)
        )

        let askTask = Task { try await chat.ask("Q") }
        try? await Task.sleep(for: .milliseconds(100))
        askTask.cancel()
        try? await Task.sleep(for: .milliseconds(100))
        state.release()

        let outcome = await askTask.result
        #expect(throws: CancellationError.self) { try outcome.get() }
        try? await Task.sleep(for: .milliseconds(300))
        let history = await chat.history
        #expect(history.isEmpty, "a cancelled ask must not be recorded in history")
    }
}

private final class LockedProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _marked = false

    var isMarked: Bool {
        lock.lock(); defer { lock.unlock() }
        return _marked
    }

    func mark() {
        lock.lock()
        _marked = true
        lock.unlock()
    }
}
