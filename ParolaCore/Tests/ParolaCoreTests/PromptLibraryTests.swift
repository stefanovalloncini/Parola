import Foundation
import Testing
@testable import ParolaCore

@Suite("Prompt library")
struct PromptLibraryTests {
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
        #expect(ok == false)
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
        let model = MockLanguageModel(scriptedResponses: ["MOCK_RESPONSE"])
        let result = try await PromptRunner.run(
            Prompt.builtIns[0],
            on: "hello",
            model: model
        )
        #expect(result == "MOCK_RESPONSE")
        let prompt = await model.receivedPrompts.last ?? ""
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

    @Test("Prompt without a version field decodes to version 1")
    func promptVersionDefaultsToOne() throws {
        let json = #"{"id":"00000000-0000-0000-0000-000000000099","name":"Legacy","instructions":"hi","isBuiltIn":false}"#
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(Prompt.self, from: data)
        #expect(decoded.version == 1)
    }

    @Test("Outdated built-in is flagged when stored version is behind")
    func outdatedBuiltInDetected() async throws {
        let url = makeTempStorage()
        let stale = [Prompt(
            id: Prompt.builtIns[0].id,
            name: Prompt.builtIns[0].name,
            instructions: Prompt.builtIns[0].instructions,
            isBuiltIn: true,
            version: 0
        )]
        let data = try JSONEncoder().encode(stale)
        try data.write(to: url)
        let lib = PromptLibrary(storageURL: url)
        let outdated = await lib.outdatedBuiltIns
        #expect(outdated.count == 1)
        #expect(outdated.first?.id == Prompt.builtIns[0].id)
        #expect(outdated.first?.storedVersion == 0)
        #expect(outdated.first?.currentVersion == 1)
    }

    @Test("dismissOutdatedBuiltIn clears the flag for that id")
    func dismissOutdatedBuiltIn() async throws {
        let url = makeTempStorage()
        let stale = [Prompt(
            id: Prompt.builtIns[0].id,
            name: Prompt.builtIns[0].name,
            instructions: Prompt.builtIns[0].instructions,
            isBuiltIn: true,
            version: 0
        )]
        let data = try JSONEncoder().encode(stale)
        try data.write(to: url)
        let lib = PromptLibrary(storageURL: url)
        await lib.dismissOutdatedBuiltIn(Prompt.builtIns[0].id)
        let outdated = await lib.outdatedBuiltIns
        #expect(outdated.isEmpty)
    }
}
