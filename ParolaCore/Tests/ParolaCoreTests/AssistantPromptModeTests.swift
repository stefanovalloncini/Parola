import Foundation
import Testing
@testable import ParolaCore

@Suite("Assistant prompt mode")
struct AssistantPromptModeTests {
    @Test("memberwise init defaults useSystemInstructions to true")
    func defaultIsTrue() {
        let p = Prompt(name: "X", instructions: "hi")
        #expect(p.useSystemInstructions)
    }

    @Test("legacy JSON without useSystemInstructions decodes to true")
    func legacyDecodeDefaultsToTrue() throws {
        let json = #"{"id":"00000000-0000-0000-0000-000000000099","name":"Legacy","instructions":"hi","isBuiltIn":false,"version":1,"triggerWords":[]}"#
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(Prompt.self, from: data)
        #expect(decoded.useSystemInstructions)
    }

    @Test("explicit useSystemInstructions = false round-trips")
    func explicitFalseRoundTrips() throws {
        let p = Prompt(name: "Ask", instructions: "answer it", useSystemInstructions: false)
        let data = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(Prompt.self, from: data)
        #expect(decoded.useSystemInstructions == false)
    }

    @Test("Assistant built-in is present with expected id and assistant mode off")
    func assistantBuiltInExists() {
        let expectedID = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
        let assistant = Prompt.builtIns.first(where: { $0.id == expectedID })
        #expect(assistant != nil)
        #expect(assistant?.name == "Assistant")
        #expect(assistant?.useSystemInstructions == false)
        #expect(assistant?.triggerWords.contains("assistant") == true)
        #expect(assistant?.triggerWords.contains("hey assistant") == true)
    }

    @Test("cleanup mode marks the text as input and leaves the instructions to the model's own")
    func cleanupEnvelopeCarriesOnlyTheInput() {
        let cleanup = Prompt(name: "Cleanup", instructions: "Clean the text below.")
        let message = PromptRunner.buildUserMessage(for: cleanup, text: "hello world")
        #expect(message == "Input:\nhello world")
        #expect(!message.contains("Clean the text below."))
    }

    @Test("assistant mode passes the user's text plain")
    func assistantMessageIsPlain() {
        let ask = Prompt(name: "Ask", instructions: "Answer it.", useSystemInstructions: false)
        let message = PromptRunner.buildUserMessage(for: ask, text: "what is the capital of france")
        #expect(message == "what is the capital of france")
        #expect(message.contains("Answer it.") == false)
        #expect(message.contains("Input:") == false)
    }

    @Test("PromptRunner.run sends the instructions once, not again in the user turn")
    func runnerUsesEnvelopeInCleanupMode() async throws {
        let model = MockLanguageModel(scriptedResponses: ["ok"])
        let cleanup = Prompt(name: "Cleanup", instructions: "Clean the text below.")
        _ = try await PromptRunner.run(cleanup, on: "hello", model: model)
        let received = await model.receivedPrompts.last ?? ""
        #expect(received == "Input:\nhello")
    }

    @Test("PromptRunner.run passes plain text in assistant mode")
    func runnerPassesPlainInAssistantMode() async throws {
        let model = MockLanguageModel(scriptedResponses: ["Paris."])
        let ask = Prompt(name: "Ask", instructions: "Answer it.", useSystemInstructions: false)
        _ = try await PromptRunner.run(ask, on: "what is the capital of france", model: model)
        let received = await model.receivedPrompts.last ?? ""
        #expect(received == "what is the capital of france")
    }
}
