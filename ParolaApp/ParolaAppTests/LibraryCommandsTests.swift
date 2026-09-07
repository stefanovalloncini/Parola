import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Bridge library commands")
struct LibraryCommandsTests {

    private func makeIsolatedDefaults() -> UserDefaults {
        temporaryDefaults()
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

    @Test("listEntries carries the duration and language the library holds")
    func listEntriesCarriesMetadata() async throws {
        let (model, server, context, commands) = try makeRig()
        let manifest = ParolaDocument.Manifest(
            originalAudioName: "talk.m4a",
            modelName: "stub",
            language: "it",
            durationSeconds: 650.0693
        )
        model.libraryEntries = [
            LibraryEntry(id: "a", bundleURL: URL(fileURLWithPath: "/tmp/a.parola"), manifest: manifest),
            entry(id: "b", title: "Beta"),
        ]
        let command = try #require(commands["listEntries"])

        let result = try await command.handler(try command.validate(AutomationArgs()), context)
        withExtendedLifetime(server) {}

        guard case .array(let items) = result, case .object(let first) = items[0],
              case .object(let second) = items[1] else {
            Issue.record("listEntries should return an array of objects")
            return
        }
        #expect(first["durationSeconds"] == .double(650.0693))
        #expect(first["language"] == .string("it"))
        #expect(second["durationSeconds"] == .null, "an entry with no measured duration reports null")
        #expect(second["language"] == .string("en"))
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
