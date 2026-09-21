import Foundation
import Testing
@testable import Parola
import ParolaCore

@MainActor
@Suite("Chat presets")
struct ChatPresetsTests {
    @Test("the preset list is built-ins minus the exclusions, then user prompts, in that order")
    func presetOrder() {
        let userPrompts = [Prompt(name: "Mine", instructions: "do a thing")]
        let presets = ChatPane.presets(userPrompts: userPrompts)

        let excludedNames: Set<String> = ["Note", "Code comment", "Assistant"]
        let expectedBuiltIns = Prompt.builtIns.filter { !excludedNames.contains($0.name) }

        #expect(presets.count == expectedBuiltIns.count + userPrompts.count)
        #expect(Array(presets.prefix(expectedBuiltIns.count)).map(\.id) == expectedBuiltIns.map(\.id))
        #expect(presets.suffix(userPrompts.count).map(\.id) == userPrompts.map(\.id))
    }

    @Test("no excluded built-in ever appears in the preset list")
    func excludesDictationAndAssistantPrompts() {
        let presets = ChatPane.presets(userPrompts: [])
        let names = Set(presets.map(\.name))
        #expect(!names.contains("Note"))
        #expect(!names.contains("Code comment"))
        #expect(!names.contains("Assistant"))
    }

    @Test("with no user prompts, the preset list is exactly the built-ins minus exclusions")
    func noUserPrompts() {
        let presets = ChatPane.presets(userPrompts: [])
        #expect(presets.count == Prompt.builtIns.count - ChatPane.excludedBuiltInIDs.count)
    }

    /// ChatPane.send(text:) is a private SwiftUI method with no seam, so this drives the same TranscriptChatSession.stream it calls.
    @Test("sending a preset's instructions through the chat session produces an assistant reply in history")
    func presetSendProducesAssistantReply() async throws {
        let preset = try #require(ChatPane.presets(userPrompts: []).first { $0.name == "Cleanup" })
        let transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "Um, hello, welcome, uh, to the meeting.")],
            language: "en",
            modelName: "stub"
        )
        let model = MockLanguageModel.make(
            response: MockLanguageModelResponse(text: "Hello, welcome to the meeting."),
            clock: ContinuousClock()
        )
        let session = TranscriptChatSession(transcript: transcript, model: model)

        var collected = ""
        for try await event in session.stream(preset.instructions) {
            if case .delta(let delta) = event { collected += delta }
        }

        let history = await session.history
        #expect(collected == "Hello, welcome to the meeting.")
        #expect(history.map(\.role) == [.user, .assistant])
        #expect(history.first?.text == preset.instructions)
        #expect(history.last?.text == "Hello, welcome to the meeting.")
    }
}
