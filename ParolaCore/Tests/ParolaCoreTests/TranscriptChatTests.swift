import Foundation
import Testing
@testable import ParolaCore

@Suite("Transcript chat")
struct TranscriptChatTests {
    private func makeTranscript() -> Transcript {
        Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "Hello world.")],
            language: "en",
            modelName: "tiny"
        )
    }

    @Test("a session built through a model maker asks the model it built")
    func sessionThroughMaker() async throws {
        let model = MockLanguageModel(scriptedResponses: ["From the chosen model"])
        let chat = try await TranscriptChat.makeSession(
            transcript: makeTranscript(),
            history: [],
            budgetTokens: 3500,
            features: .all,
            makeModel: { _ in model }
        )
        let assistant = try await chat.ask("Who are you?")
        #expect(assistant.text == "From the chosen model")
    }

    @Test("a transcript over the budget is condensed through the same maker, not refused")
    func sessionCondensesOverBudget() async throws {
        let long = Transcript(
            segments: (0..<400).map {
                TranscriptSegment(id: $0, start: Double($0), end: Double($0) + 1, text: "parola parola parola parola parola")
            },
            language: "it",
            modelName: "tiny"
        )
        let handedInstructions = InstructionLog()
        // A fresh model per call: the digest is summarised window by window, each with its own maker call.
        let chat = try await TranscriptChat.makeSession(
            transcript: long,
            history: [],
            budgetTokens: 3500,
            features: .all,
            makeModel: { instructions in
                await handedInstructions.record(instructions)
                return instructions.contains("RELEVANT EXCERPTS:")
                    ? MockLanguageModel(scriptedResponses: ["Answered from the condensed session"])
                    : MockLanguageModel(scriptedResponses: ["SUMMARY:\nUn riassunto.\n"])
            }
        )
        let assistant = try await chat.ask("Di cosa si parla?")

        #expect(assistant.text == "Answered from the condensed session")
        // The digest and the answer both come from the maker: the probe, the summary and the question.
        #expect(await handedInstructions.count >= 3)
        #expect(await handedInstructions.last?.contains("RELEVANT EXCERPTS:") == true)
    }

    @Test("the budget for a choice follows the model behind it")
    func budgetPerChoice() {
        #expect(TranscriptChat.budgetTokens(for: .onDevice) == TranscriptChat.defaultBudgetTokens)
        #expect(TranscriptChat.budgetTokens(for: .cloud(provider: .openAI, model: "gpt-4o-mini")) > 100_000)
        #expect(TranscriptChat.budgetTokens(for: .ollama(endpoint: URL(string: "http://127.0.0.1:11434")!, model: "llama3.2:3b")) >= TranscriptChat.defaultBudgetTokens)
        #expect(TranscriptChat.budgetTokens(for: .custom(baseURL: URL(string: "http://10.0.0.2:8080/v1")!, model: "m")) == TranscriptChat.defaultBudgetTokens)
    }

    @Test("first ask records user and assistant messages")
    func firstAsk() async throws {
        let model = MockLanguageModel(scriptedResponses: ["Hi there!"])
        let chat = TranscriptChatSession(transcript: makeTranscript(), model: model)
        let assistant = try await chat.ask("Hello?")
        #expect(assistant.role == .assistant)
        #expect(assistant.text == "Hi there!")
        let history = await chat.history
        #expect(history.count == 2)
        #expect(history[0].role == .user)
        #expect(history[0].text == "Hello?")
        #expect(history[1].role == .assistant)
        #expect(history[1].text == "Hi there!")
    }

    @Test("multi-turn conversation preserves order")
    func multiTurn() async throws {
        let model = MockLanguageModel(scriptedResponses: ["Answer 1", "Answer 2"])
        let chat = TranscriptChatSession(transcript: makeTranscript(), model: model)
        _ = try await chat.ask("Q1")
        _ = try await chat.ask("Q2")
        let history = await chat.history
        #expect(history.map(\.text) == ["Q1", "Answer 1", "Q2", "Answer 2"])
    }

    @Test("second turn forwards full prior history to the model")
    func multiTurnHistoryThreading() async throws {
        let model = MockLanguageModel(scriptedResponses: ["Answer 1", "Answer 2"])
        let chat = TranscriptChatSession(transcript: makeTranscript(), model: model)
        _ = try await chat.ask("Q1")
        _ = try await chat.ask("Q2")
        let lastHistory = await model.lastReceivedHistory
        #expect(lastHistory?.count == 3)
        #expect(lastHistory?.map(\.text) == ["Q1", "Answer 1", "Q2"])
        #expect(lastHistory?.map(\.role) == [.user, .assistant, .user])
    }

    @Test("clearHistory empties the conversation")
    func clear() async throws {
        let model = MockLanguageModel(scriptedResponses: ["Answer"])
        let chat = TranscriptChatSession(transcript: makeTranscript(), model: model)
        _ = try await chat.ask("Q")
        await chat.clearHistory()
        let history = await chat.history
        #expect(history.isEmpty)
    }

    @Test("initial history is restored and forwarded to the model")
    func resumeWithHistory() async throws {
        let prior = [
            ChatMessage(role: .user, text: "Previous Q"),
            ChatMessage(role: .assistant, text: "Previous A"),
        ]
        let model = MockLanguageModel(scriptedResponses: ["Reply"])
        let chat = TranscriptChatSession(transcript: makeTranscript(), history: prior, model: model)
        _ = try await chat.ask("New Q")
        let history = await chat.history
        #expect(history.count == 4)
        #expect(history.first?.text == "Previous Q")
        #expect(history.last?.text == "Reply")
        let lastHistory = await model.lastReceivedHistory
        #expect(lastHistory?.map(\.text) == ["Previous Q", "Previous A", "New Q"])
    }

    @Test("failed ask leaves history unchanged")
    func askFailureLeavesHistoryUntouched() async throws {
        let model = MockLanguageModel(error: NSError(domain: "test", code: 1))
        let chat = TranscriptChatSession(transcript: makeTranscript(), model: model)
        var didThrow = false
        do {
            _ = try await chat.ask("Q")
        } catch {
            didThrow = true
        }
        #expect(didThrow)
        let history = await chat.history
        #expect(history.isEmpty)
    }

    @Test("retry after a failed ask succeeds and records a clean turn")
    func askRetryAfterFailure() async throws {
        let model = MockLanguageModel(error: NSError(domain: "test", code: 1))
        let chat = TranscriptChatSession(transcript: makeTranscript(), model: model)
        do { _ = try await chat.ask("Q1") } catch {}
        await model.setError(nil)
        await model.enqueue("Answer 1")
        _ = try await chat.ask("Q1")
        let history = await chat.history
        #expect(history.map(\.text) == ["Q1", "Answer 1"])
    }

    @Test("stream yields deltas then a completed message")
    func streamYieldsDeltasAndCompletion() async throws {
        let model = MockLanguageModel(scriptedResponses: ["Hi!"])
        let chat = TranscriptChatSession(transcript: makeTranscript(), model: model)
        var collected = ""
        var completed: ChatMessage?
        for try await event in chat.stream("Hello?") {
            switch event {
            case .delta(let text): collected += text
            case .completed(let message): completed = message
            }
        }
        #expect(collected == "Hi!")
        #expect(completed?.text == "Hi!")
        let history = await chat.history
        #expect(history.map(\.text) == ["Hello?", "Hi!"])
    }

    @Test("ChatMessage round-trips through JSON")
    func chatMessageJSON() throws {
        let msg = ChatMessage(role: .assistant, text: "Hello")
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)
        #expect(decoded.role == .assistant)
        #expect(decoded.text == "Hello")
    }

    @Test("Transcript chatHistory survives JSON round-trip")
    func transcriptChatHistory() throws {
        var t = makeTranscript()
        t.chatHistory = [ChatMessage(role: .user, text: "Q")]
        let data = try JSONEncoder().encode(t)
        let decoded = try JSONDecoder().decode(Transcript.self, from: data)
        #expect(decoded.chatHistory?.count == 1)
        #expect(decoded.chatHistory?.first?.text == "Q")
    }

    @Test("system instructions include transcript text")
    func instructions() {
        let transcript = Transcript(
            segments: [
                TranscriptSegment(id: 0, start: 0, end: 1, text: "Hello there"),
                TranscriptSegment(id: 1, start: 65, end: 70, text: "Goodbye"),
            ],
            language: "en",
            modelName: "tiny"
        )
        let instructions = TranscriptChat.systemInstructions(for: transcript)
        #expect(instructions.contains("Hello there"))
        #expect(instructions.contains("Goodbye"))
        #expect(instructions.contains("00:00"))
        #expect(instructions.contains("01:05"))
    }
}

/// What a model maker was handed, in order.
private actor InstructionLog {
    private(set) var all: [String] = []
    var count: Int { all.count }
    var last: String? { all.last }
    func record(_ instructions: String) { all.append(instructions) }
}
