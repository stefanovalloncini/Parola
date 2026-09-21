import Foundation
import Testing
@testable import ParolaCore

@Suite("Prompt built-ins")
struct PromptBuiltInsTests {
    @Test("there are 19 built-in prompts")
    func count() {
        #expect(Prompt.builtIns.count == 19)
    }

    @Test("every built-in has a unique id")
    func uniqueIDs() {
        let ids = Prompt.builtIns.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("every built-in has a unique name")
    func uniqueNames() {
        let names = Prompt.builtIns.map(\.name)
        #expect(Set(names).count == names.count)
    }

    @Test("every built-in has non-empty instructions")
    func nonEmptyInstructions() {
        for prompt in Prompt.builtIns {
            #expect(!prompt.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(prompt.name) has empty instructions")
        }
    }

    @Test("every built-in is flagged isBuiltIn with version 1")
    func flagsAndVersion() {
        for prompt in Prompt.builtIns {
            #expect(prompt.isBuiltIn)
            #expect(prompt.version == 1)
        }
    }
}
