import Foundation
import Testing
@testable import ParolaCore

@Suite("Transcript chat")
struct TranscriptChatTests {
    private actor MockLanguageModel: LanguageModel {
        var scriptedResponses: [String]
        var receivedPrompts: [String] = []

        init(scriptedResponses: [String]) {
            self.scriptedResponses = scriptedResponses
        }

        func respond(to prompt: String) async throws -> String {
            receivedPrompts.append(prompt)
            guard !scriptedResponses.isEmpty else { return "" }
            return scriptedResponses.removeFirst()
        }
    }

    private func makeTranscript() -> Transcript {
        Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "Hello world.")],
            language: "en",
            modelName: "tiny"
        )
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

    @Test("clearHistory empties the conversation")
    func clear() async throws {
        let model = MockLanguageModel(scriptedResponses: ["Answer"])
        let chat = TranscriptChatSession(transcript: makeTranscript(), model: model)
        _ = try await chat.ask("Q")
        await chat.clearHistory()
        let history = await chat.history
        #expect(history.isEmpty)
    }

    @Test("initial history is restored")
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
