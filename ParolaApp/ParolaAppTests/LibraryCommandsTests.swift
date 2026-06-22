import Foundation
import Testing
@testable import Parola
import ParolaCore

@MainActor
@Suite("Bridge library commands")
struct LibraryCommandsTests {

    private func makeIsolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test-\(UUID())")!
    }

    private func makeRig() throws -> (AppModel, ParolaAutomationServer, AutomationContext, [String: AutomationCommand]) {
        let model = AppModel(skipBootstrap: true, defaults: makeIsolatedDefaults(), libraryURL: makeTempLibraryURL("librarycommands"))
        let server = try ParolaAutomationServer(model: model)
        let context = AutomationContext(model: model, server: server)
        let commands = Dictionary(uniqueKeysWithValues: server.libraryCommands().map { ($0.name, $0) })
        return (model, server, context, commands)
    }

    private func entry(id: String, title: String) -> LibraryEntry {
        let manifest = ParolaDocument.Manifest(originalAudioName: "\(title).m4a", modelName: "stub", language: "en")
        return LibraryEntry(id: id, bundleURL: URL(fileURLWithPath: "/tmp/LibraryCommandsTests/\(id).parola"), manifest: manifest)
    }

    private func arrayCount(_ value: AutomationValue) -> Int? {
        guard case .array(let items) = value else { return nil }
        return items.count
    }

    @Test("listEntries clamps a negative limit to empty instead of trapping")
    func listEntriesNegativeLimit() async throws {
        let (model, server, context, commands) = try makeRig()
        model.libraryEntries = [entry(id: "a", title: "Alpha"), entry(id: "b", title: "Beta")]
        let command = try #require(commands["listEntries"])
        let args = try command.validate(AutomationArgs(["limit": .int(-1)]))

        let result = try await command.handler(args, context)
        withExtendedLifetime(server) {}

        #expect(arrayCount(result) == 0)
    }

    @Test("listDeletedEntries clamps a negative limit to empty instead of trapping")
    func listDeletedEntriesNegativeLimit() async throws {
        let (model, server, context, commands) = try makeRig()
        model.deletedEntries = [entry(id: "x", title: "Gone")]
        let command = try #require(commands["listDeletedEntries"])
        let args = try command.validate(AutomationArgs(["limit": .int(-1)]))

        let result = try await command.handler(args, context)
        withExtendedLifetime(server) {}

        #expect(arrayCount(result) == 0)
    }
}
