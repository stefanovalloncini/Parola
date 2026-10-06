import Foundation
import Testing
@testable import ParolaCore

/// Parks on `gate` until the test opens it; the signals say how far the session's cancellation reached.
private struct GatedLanguageModel: LanguageModel {
    let gate = UninterruptibleGate()
    let terminated = TestSignal()
    let streamClosed = TestSignal()

    func respond(history: [ChatTurn]) async throws -> String {
        await gate.wait()
        return "Late answer"
    }

    func stream(history: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield("Hello")
                await gate.wait()
                continuation.yield(" world")
                streamClosed.fire()
                continuation.finish()
            }
            continuation.onTermination = { reason in
                if case .cancelled = reason {
                    terminated.fire()
                    streamClosed.fire()
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

    @Test("cancelling the stream consumer reaches the model and appends nothing to history")
    func streamCancellationPropagates() async throws {
        let model = GatedLanguageModel()
        let chat = TranscriptChatSession(transcript: makeTranscript(), model: model)

        let firstDelta = TestSignal()
        let consumer = Task {
            for try await event in chat.stream("Q") {
                if case .delta = event { firstDelta.fire() }
            }
        }
        await firstDelta.wait("the first delta to reach the consumer")

        consumer.cancel()
        model.gate.open()

        await model.streamClosed.wait("the model stream to wind down after cancellation")
        await model.terminated.wait("cancellation to propagate into the model's stream")

        // A later ask runs after the cancelled generation's task, so the history it adds to is final.
        let answer = try await chat.ask("Follow-up")
        #expect(answer.text == "Late answer")
        let history = await chat.history
        #expect(history.map(\.text) == ["Follow-up", "Late answer"], "a cancelled generation must not be recorded in history")
    }

    @Test("a stopped reply the caller keeps stays in history, ahead of the next reply, and in its context")
    func keptStoppedReplyStays() async throws {
        let model = GatedLanguageModel()
        let chat = TranscriptChatSession(transcript: makeTranscript(), model: model)
        let question = ChatMessage(role: .user, text: "Q")

        let firstDelta = TestSignal()
        let consumer = Task {
            for try await event in chat.stream(question.text, id: question.id) {
                if case .delta = event { firstDelta.fire() }
            }
        }
        await firstDelta.wait("the first delta to reach the consumer")
        consumer.cancel()
        let kept = await chat.keepStopped(question: question, reply: ChatMessage(role: .assistant, text: "Hello"))
        #expect(kept.map(\.text) == ["Q", "Hello"])
        model.gate.open()
        await model.streamClosed.wait("the stopped stream to wind down")

        let context = await chat.turns(for: ChatMessage(role: .user, text: "Next")).map(\.text)
        #expect(context == ["Q", "Hello", "Next"])
        for try await _ in chat.stream("Next") {}
        let history = await chat.history
        #expect(history.map(\.text) == ["Q", "Hello", "Next", "Hello world"])
    }

    @Test("keeping a reply whose turn already finished records it once")
    func keptFinishedReplyIsNotDoubled() async throws {
        let model = GatedLanguageModel()
        model.gate.open()
        let chat = TranscriptChatSession(transcript: makeTranscript(), model: model)
        let question = ChatMessage(role: .user, text: "Q")
        for try await _ in chat.stream(question.text, id: question.id) {}

        let kept = await chat.keepStopped(question: question, reply: ChatMessage(role: .assistant, text: "Hello"))
        #expect(kept.map(\.text) == ["Q", "Hello world"])
        #expect(kept.first?.id == question.id)
    }

    @Test("cancelling ask surfaces CancellationError and appends nothing to history")
    func askCancellationPropagates() async throws {
        let model = GatedLanguageModel()
        let chat = TranscriptChatSession(transcript: makeTranscript(), model: model)

        let askTask = Task { try await chat.ask("Q") }
        await model.gate.arrivals.wait(atLeast: 1, "the ask to reach the model")
        askTask.cancel()
        model.gate.open()

        let outcome = await askTask.result
        #expect(throws: CancellationError.self) { try outcome.get() }
        let history = await chat.history
        #expect(history.isEmpty, "a cancelled ask must not be recorded in history")
    }
}
