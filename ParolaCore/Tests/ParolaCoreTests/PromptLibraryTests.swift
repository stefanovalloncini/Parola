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
        let original = await lib.addUserPrompt(name: "Old", instructions: "old").prompt
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
        var builtIn = try #require(Prompt.builtIns.first)
        builtIn.name = "Hacked"
        let ok = await lib.updateUserPrompt(builtIn)
        #expect(ok == false)
    }

    @Test("removing a user prompt drops it")
    func removeUserPrompt() async throws {
        let lib = PromptLibrary(storageURL: makeTempStorage())
        let p = await lib.addUserPrompt(name: "X", instructions: "y").prompt
        let ok = await lib.removeUserPrompt(p.id)
        #expect(ok)
        let userPrompts = await lib.userPrompts
        #expect(userPrompts.isEmpty)
    }

    @Test("an unparseable prompt file is kept aside instead of overwritten")
    func unreadableFileIsPreserved() async throws {
        let url = makeTempStorage()
        let original = Data("{ this is not a prompt list".utf8)
        try original.write(to: url)

        let lib = PromptLibrary(storageURL: url)
        #expect(await lib.userPrompts.isEmpty)
        #expect(await lib.loadFailure != nil)

        _ = await lib.addUserPrompt(name: "Fresh", instructions: "new")
        let backup = url.appendingPathExtension("corrupt")
        #expect((try? Data(contentsOf: backup)) == original)
        #expect(await lib.lastSaveFailed == false)
        #expect(await lib.loadFailure == nil)
    }

    @Test("every kept-aside copy of an unparseable file survives the next one")
    func repeatedCorruptionKeepsEveryCopy() async throws {
        let url = makeTempStorage()
        for round in 1...22 {
            try Data("{ broken \(round)".utf8).write(to: url)
            let lib = PromptLibrary(storageURL: url)
            _ = await lib.addUserPrompt(name: "Fresh \(round)", instructions: "new")
            #expect(await lib.lastSaveFailed == false)
        }
        let parent = url.deletingLastPathComponent()
        let kept = try FileManager.default.contentsOfDirectory(atPath: parent.path)
            .filter { $0.hasPrefix(url.lastPathComponent + ".corrupt") }
        #expect(kept.count == 22)
    }

    @Test("a file that cannot be read is neither overwritten nor renamed")
    func unreadableFileIsLeftAlone() async throws {
        let url = makeTempStorage()
        let original = try JSONEncoder().encode([Prompt(name: "Mine", instructions: "keep", isBuiltIn: false)])
        try original.write(to: url)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)

        let lib = PromptLibrary(storageURL: url)
        #expect(await lib.loadFailure == .unreadable)

        let added = await lib.addUserPrompt(name: "Fresh", instructions: "new")
        #expect(added.saved == false)
        #expect(await lib.lastSaveFailed)
        #expect(FileManager.default.fileExists(atPath: url.appendingPathExtension("corrupt").path) == false)

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #expect(try Data(contentsOf: url) == original)
    }

    @Test("a missing prompt file starts empty and still saves")
    func missingFileStartsEmpty() async throws {
        let url = makeTempStorage()
        let lib = PromptLibrary(storageURL: url)
        #expect(await lib.userPrompts.isEmpty)
        #expect(await lib.loadFailure == nil)

        #expect(await lib.addUserPrompt(name: "Fresh", instructions: "new").saved)
        #expect(await lib.lastSaveFailed == false)
        #expect(FileManager.default.fileExists(atPath: url.appendingPathExtension("corrupt").path) == false)

        let reloaded = PromptLibrary(storageURL: url)
        #expect(await reloaded.userPrompts.count == 1)
    }

    @Test("a save that cannot be written is reported to the caller")
    func saveFailureIsReported() async throws {
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-prompts-blocker-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: blocker)
        let lib = PromptLibrary(storageURL: blocker.appendingPathComponent("Prompts.json"))

        let added = await lib.addUserPrompt(name: "Nope", instructions: "n")
        #expect(added.saved == false)
        #expect(await lib.lastSaveFailed)
        #expect(await lib.updateUserPrompt(added.prompt) == false)
        #expect(await lib.removeUserPrompt(added.prompt.id) == false)
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
        #expect(await model.receivedPrompts.last == "Input:\nhello")
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
