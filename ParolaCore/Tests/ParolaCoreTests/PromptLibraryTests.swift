import Foundation
import Testing
@testable import ParolaCore

@Suite("Prompt library")
struct PromptLibraryTests {
    private actor MockModel: LanguageModel {
        var lastPrompt: String = ""
        func respond(to prompt: String) async throws -> String {
            lastPrompt = prompt
            return "MOCK_RESPONSE"
        }
    }

    private func makeTempStorage() -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-prompts-test-\(UUID().uuidString).json")
        return tmp
    }

    @Test("fresh library includes all built-in prompts")
    func builtInsPresent() async throws {
        let lib = PromptLibrary(storageURL: makeTempStorage())
        let all = await lib.allPrompts
        let builtInIDs = Set(Prompt.builtIns.map(\.id))
        let presentBuiltIns = all.filter(\.isBuiltIn).map(\.id)
        #expect(Set(presentBuiltIns) == builtInIDs)
    }

    @Test("adding a user prompt persists across instances")
    func userPromptPersists() async throws {
        let url = makeTempStorage()
        let lib1 = PromptLibrary(storageURL: url)
        _ = await lib1.addUserPrompt(name: "Spicy", instructions: "Spice up the text.")
        let lib2 = PromptLibrary(storageURL: url)
        let userPrompts = await lib2.userPrompts
        #expect(userPrompts.count == 1)
        #expect(userPrompts.first?.name == "Spicy")
        #expect(userPrompts.first?.isBuiltIn == false)
    }

    @Test("updating a user prompt overwrites name and instructions")
    func updateUserPrompt() async throws {
        let lib = PromptLibrary(storageURL: makeTempStorage())
        let original = await lib.addUserPrompt(name: "Old", instructions: "old")
        var edited = original
        edited.name = "New"
        edited.instructions = "new"
        let ok = await lib.updateUserPrompt(edited)
        #expect(ok)
        let userPrompts = await lib.userPrompts
        #expect(userPrompts.first?.name == "New")
        #expect(userPrompts.first?.instructions == "new")
    }

    @Test("updating a built-in prompt is rejected")
    func cannotUpdateBuiltIn() async throws {
        let lib = PromptLibrary(storageURL: makeTempStorage())
        var builtIn = Prompt.builtIns.first!
        builtIn.name = "Hacked"
        let ok = await lib.updateUserPrompt(builtIn)
        #expect(!ok)
    }

    @Test("removing a user prompt drops it")
    func removeUserPrompt() async throws {
        let lib = PromptLibrary(storageURL: makeTempStorage())
        let p = await lib.addUserPrompt(name: "X", instructions: "y")
        let ok = await lib.removeUserPrompt(p.id)
        #expect(ok)
        let userPrompts = await lib.userPrompts
        #expect(userPrompts.isEmpty)
    }

    @Test("PromptRunner dispatches via the language model")
    func runnerDispatches() async throws {
        let model = MockModel()
        let result = try await PromptRunner.run(
            Prompt.builtIns[0],
            on: "hello",
            model: model
        )
        #expect(result == "MOCK_RESPONSE")
        let prompt = await model.lastPrompt
        #expect(prompt.contains("Cleanup the transcript") || prompt.contains("Clean up the transcript"))
        #expect(prompt.contains("hello"))
    }

    @Test("Prompt round-trips through JSON")
    func promptJSON() throws {
        let p = Prompt(name: "Test", instructions: "test", isBuiltIn: false)
        let data = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(Prompt.self, from: data)
        #expect(decoded.id == p.id)
        #expect(decoded.name == "Test")
    }
}
