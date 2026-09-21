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
}
