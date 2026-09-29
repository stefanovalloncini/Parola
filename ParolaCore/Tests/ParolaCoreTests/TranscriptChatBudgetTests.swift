import Foundation
import Testing
@testable import ParolaCore

#if canImport(FoundationModels)
import FoundationModels
#endif

@Suite("Transcript chat history budget")
struct TranscriptChatBudgetTests {
    private let transcript = Transcript(
        segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "Hello world.")],
        language: "en",
        modelName: "tiny"
    )

    /// 400-token window, 100 held for the answer: 50 of that for the reply, 250 for turns beside 100 of instructions.
    private let budget = TokenBudget(contextTokens: 400, answerTokens: 100, counting: .bytes(perToken: 4))

    private func savedHistory(_ pairs: Int) -> [ChatMessage] {
        (0..<pairs).flatMap { i in
            [
                ChatMessage(role: .user, text: "question \(i) " + String(repeating: "x", count: 80)),
                ChatMessage(role: .assistant, text: "answer \(i) " + String(repeating: "y", count: 80)),
            ]
        }
    }

    @Test("only the newest turns that fit are replayed, starting on a question")
    func replaysTheNewestTurnsThatFit() async throws {
        let model = MockLanguageModel(scriptedResponses: ["ok"])
        let session = TranscriptChatSession(
            transcript: transcript, history: savedHistory(10), model: model, budget: budget, instructionTokens: 100
        )

        _ = try await session.ask("What next?")

        let sent = try #require(await model.lastReceivedHistory)
        #expect(sent.count > 1)
        #expect(sent.count < 21)
        #expect(sent.first?.role == .user)
        #expect(sent.last?.text == "What next?")
        #expect(sent.dropLast().last?.text.hasPrefix("answer 9 ") == true)
        let used = sent.reduce(0) { $0 + budget.estimate($1.text) + 4 }
        #expect(used <= 250)
        #expect(await session.history.count == 22)
    }

    @Test("without a budget every turn is replayed")
    func unboundedReplaysAll() async throws {
        let model = MockLanguageModel(scriptedResponses: ["ok"])
        let session = TranscriptChatSession(transcript: transcript, history: savedHistory(10), model: model)
        _ = try await session.ask("What next?")
        #expect(await model.lastReceivedHistory?.count == 21)
        #expect(session.messageCharacterLimit == nil)
    }

    @Test("an attachment gets half the room the turns have")
    func messageLimitFollowsTheRoom() {
        let session = TranscriptChatSession(
            transcript: transcript, model: MockLanguageModel(), budget: budget, instructionTokens: 100
        )
        #expect(session.messageCharacterLimit == 125 * 4)
    }

    @Test("a cloud chat keeps the whole answer share free, as the provider's own check demands")
    func cloudChatLeavesTheAnswerShare() async throws {
        let cloud = TokenBudget(for: .cloud(provider: .openAI, model: "gpt-4o-mini"))
        let instructionTokens = cloud.tokens - 300
        let model = MockLanguageModel(scriptedResponses: ["ok"])
        let session = TranscriptChatSession(
            transcript: transcript, history: savedHistory(10), model: model, budget: cloud, instructionTokens: instructionTokens
        )

        _ = try await session.ask("What next?")

        let sent = try #require(await model.lastReceivedHistory)
        #expect(sent.count > 1)
        let used = instructionTokens + sent.reduce(0) { $0 + TokenBudget.estimateTokens($1.text) + 4 }
        #expect(used <= cloud.contextTokens - 4096)
    }

    @Test("a condensed chat leaves room in its instructions for the latest turns")
    func condensedChatKeepsRecentTurns() async throws {
        let strict = TokenBudget(
            contextTokens: 8000, answerTokens: 2000, counting: .bytes(perToken: 4),
            maxAnswerTokens: 2000, chatReplyTokens: 2000
        )
        let long = Transcript(
            segments: (0..<600).map {
                TranscriptSegment(id: $0, start: Double($0) * 5, end: Double($0) * 5 + 4, text: "we talked about the plan for the launch and the budget")
            },
            language: "en",
            modelName: "tiny"
        )
        let log = HandedInstructions()
        let answering = MockLanguageModel(scriptedResponses: ["ok"])
        let session = try await TranscriptChat.makeSession(
            transcript: long,
            history: savedHistory(4),
            budget: strict,
            digest: { Summary(text: "A launch meeting.") },
            features: .all,
            makeModel: { instructions in
                await log.record(instructions)
                return answering
            }
        )

        _ = try await session.ask("What about the launch budget?")

        let instructions = try #require(await log.last)
        #expect(instructions.contains("RELEVANT EXCERPTS:"))
        let sent = try #require(await answering.lastReceivedHistory)
        #expect(sent.count > 1)
        let used = strict.estimate(instructions) + sent.reduce(0) { $0 + strict.estimate($1.text) + 4 }
        #expect(used <= strict.contextTokens - 2000)
    }

    @Test("a context overflow is retried once with the question alone")
    func overflowRetriesWithTheQuestionAlone() async throws {
        let model = OverflowOnceModel()
        let session = TranscriptChatSession(
            transcript: transcript, history: savedHistory(2), model: model, budget: budget, instructionTokens: 100
        )

        let answer = try await session.ask("And then?")

        #expect(answer.text == "recovered")
        let histories = await model.histories
        #expect(histories.count == 2)
        #expect(histories[0].count == 5)
        #expect(histories[1].map(\.text) == ["And then?"])
        #expect(await session.history.count == 6)
    }

    @Test("a streamed context overflow is retried once before any text arrives")
    func streamedOverflowRetries() async throws {
        let model = OverflowOnceModel()
        let session = TranscriptChatSession(
            transcript: transcript, history: savedHistory(2), model: model, budget: budget, instructionTokens: 100
        )

        var completed: ChatMessage?
        for try await event in session.stream("And then?") {
            if case .completed(let message) = event { completed = message }
        }

        #expect(completed?.text == "recovered")
        #expect(await model.histories.last?.map(\.text) == ["And then?"])
    }

    @Test("a second overflow surfaces and records nothing")
    func secondOverflowFails() async throws {
        let model = MockLanguageModel(error: CloudLLMError.tokenBudgetExceeded(provider: .openAI, used: 10, limit: 1))
        let session = TranscriptChatSession(
            transcript: transcript, history: savedHistory(2), model: model, budget: budget, instructionTokens: 100
        )
        await #expect(throws: TranscriptChatSession.FailureReason.self) {
            _ = try await session.ask("And then?")
        }
        #expect(await model.receivedHistories.count == 2)
        #expect(await session.history.count == 4)
    }

    @Test("on-device chat goes through the factory, so a stand-in answers it")
    func onDeviceChatIsMockable() async throws {
        let (reply, instructions) = try await MockLanguageModelStore.shared.withLease {
            await MockLanguageModelStore.shared.clear()
            await MockLanguageModelStore.shared.install(provider: .foundation, response: MockLanguageModelResponse(text: "from the stand-in"))
            let session = try? await TranscriptChat.makeSession(transcript: transcript, features: .all)
            let reply = try? await session?.ask("what was said?")
            let instructions = await MockLanguageModelStore.shared.lastInstructions(for: .foundation)
            await MockLanguageModelStore.shared.clear()
            return (reply?.text, instructions)
        }
        #expect(reply == "from the stand-in")
        #expect(instructions?.contains("Hello world.") == true)
    }

    @Test("an unavailable on-device model reaches the chat as its own sentence")
    func onDeviceUnavailableIsOneError() async throws {
        let thrown = try await MockLanguageModelStore.shared.withLease { () -> (any Error)? in
            await MockLanguageModelStore.shared.clear()
            await MockLanguageModelStore.shared.install(
                provider: .foundation,
                response: MockLanguageModelResponse(failure: MockLanguageModelFailure(code: .notAvailable, message: "Apple Intelligence is off."))
            )
            var thrown: (any Error)?
            do {
                let session = try await TranscriptChat.makeSession(transcript: transcript, features: .all)
                _ = try await session.ask("anything?")
            } catch {
                thrown = error
            }
            await MockLanguageModelStore.shared.clear()
            return thrown
        }
        #expect(thrown?.localizedDescription.contains("Apple Intelligence is off.") == true)
    }

    @Test("every provider's overflow reads as one")
    func overflowDetection() {
        #expect(LanguageModelFactory.isContextOverflow(CloudLLMError.tokenBudgetExceeded(provider: .openAI, used: 2, limit: 1)))
        #expect(!LanguageModelFactory.isContextOverflow(CloudLLMError.missingAPIKey(.openAI)))
        #expect(!LanguageModelFactory.isContextOverflow(CancellationError()))
        #if canImport(FoundationModels)
        if #available(macOS 27.0, iOS 27.0, visionOS 27.0, *) {
            let exceeded = LanguageModelError.contextSizeExceeded(
                .init(contextSize: 4096, tokenCount: 5000, debugDescription: "too long")
            )
            #expect(LanguageModelFactory.isContextOverflow(exceeded))
        }
        if #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) {
            let exceeded = LanguageModelSession.GenerationError.exceededContextWindowSize(.init(debugDescription: "too long"))
            #expect(LanguageModelFactory.isContextOverflow(exceeded))
        }
        #endif
    }
}

/// Refuses the first request as too long, then answers.
private actor OverflowOnceModel: ParolaCore.LanguageModel {
    private(set) var histories: [[ChatTurn]] = []

    private func next(_ history: [ChatTurn]) throws -> String {
        histories.append(history)
        if histories.count == 1 {
            throw CloudLLMError.tokenBudgetExceeded(provider: .openAI, used: 10_000, limit: 100)
        }
        return "recovered"
    }

    func respond(history: [ChatTurn]) async throws -> String {
        try next(history)
    }

    nonisolated func stream(history: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    continuation.yield(try await self.next(history))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

private actor HandedInstructions {
    private(set) var last: String?
    func record(_ instructions: String) { last = instructions }
}
