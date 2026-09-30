import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Bridge settings commands")
struct SettingsCommandsTests {

    private func makeRig() throws -> (AppModel, ParolaAutomationServer, AutomationContext, [String: AutomationCommand]) {
        let model = AppModel(
            skipBootstrap: true,
            defaults: temporaryDefaults(),
            libraryURL: makeTempLibraryURL("settingscommands")
        )
        let server = try ParolaAutomationServer(model: model)
        let context = AutomationContext(model: model, server: server)
        let commands = Dictionary(uniqueKeysWithValues: server.settingsCommands().map { ($0.name, $0) })
        return (model, server, context, commands)
    }

    private func run(
        _ commands: [String: AutomationCommand],
        _ name: String,
        _ args: [String: AutomationValue],
        _ context: AutomationContext
    ) async throws -> AutomationValue {
        let command = try #require(commands[name])
        return try await command.handler(command.validate(AutomationArgs(args)), context)
    }

    @Test("category 'all' shows the whole Library page")
    func setLibraryFilterAll() async throws {
        let (model, server, context, commands) = try makeRig()
        model.route = .batch

        let result = try await run(commands, "setLibraryFilter", ["category": .string("all")], context)
        withExtendedLifetime(server) {}

        #expect(model.libraryFilter == nil)
        #expect(model.isBrowsingLibrary)
        #expect(model.route == .transcript)
        #expect(result == .object([
            "libraryFilter": .string("all"),
            "libraryBrowsingAll": .bool(true),
        ]))
        guard case .object(let state) = server.snapshotState() else {
            Issue.record("snapshotState should return an object")
            return
        }
        #expect(state["libraryBrowsingAll"] == .bool(true))
    }

    @Test("category 'all' over an open transcript replies once the Library page is up")
    func setLibraryFilterAllOverATranscript() async throws {
        let (model, server, context, commands) = try makeRig()
        model.transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "still open")],
            language: "en",
            modelName: "stub"
        )
        model.phase = .ready

        let result = try await run(commands, "setLibraryFilter", ["category": .string("all")], context)
        withExtendedLifetime(server) {}

        #expect(model.transcript == nil)
        #expect(result == .object([
            "libraryFilter": .string("all"),
            "libraryBrowsingAll": .bool(true),
        ]))
    }

    @Test("a category filter leaves the whole library behind")
    func setLibraryFilterCategory() async throws {
        let (model, server, context, commands) = try makeRig()

        let result = try await run(commands, "setLibraryFilter", ["category": .string("meeting")], context)
        withExtendedLifetime(server) {}

        #expect(model.libraryFilter == .meeting)
        #expect(model.route == .transcript)
        #expect(result == .object([
            "libraryFilter": .string("meeting"),
            "libraryBrowsingAll": .bool(false),
        ]))
    }

    @Test("an empty category shows the whole Library page and clears the search")
    func setLibraryFilterCleared() async throws {
        let (model, server, context, commands) = try makeRig()
        model.libraryFilter = .dictation
        model.searchQuery = "bianchi"

        let result = try await run(commands, "setLibraryFilter", ["category": .string("")], context)
        withExtendedLifetime(server) {}

        #expect(model.libraryFilter == nil)
        #expect(model.route == .transcript)
        #expect(model.searchQuery.isEmpty)
        #expect(result == .object([
            "libraryFilter": .string(""),
            "libraryBrowsingAll": .bool(true),
        ]))
    }

    @Test("an unknown category is still rejected")
    func setLibraryFilterUnknown() async throws {
        let (_, server, context, commands) = try makeRig()
        await #expect(throws: AutomationError.self) {
            _ = try await run(commands, "setLibraryFilter", ["category": .string("podcasts")], context)
        }
        withExtendedLifetime(server) {}
    }

    @Test("the inspector tab is writable through the bridge")
    func inspectorModeIsWritable() async throws {
        let (model, server, context, commands) = try makeRig()

        _ = try await run(
            commands,
            "setSetting",
            ["key": .string("inspectorMode"), "value": .string("info")],
            context
        )
        withExtendedLifetime(server) {}

        #expect(model.defaults.string(forKey: "inspectorMode") == "info")
    }

    @Test("the bridge can turn the library's date groups off, and a backup keeps the choice")
    func groupByDateIsWritable() async throws {
        let (model, server, context, commands) = try makeRig()
        #expect(model.libraryGroupsByDate)

        _ = try await run(
            commands,
            "setSetting",
            ["key": .string("libraryGroupsByDate"), "value": .bool(false)],
            context
        )
        withExtendedLifetime(server) {}

        #expect(!model.libraryGroupsByDate)
        #expect(UnscopedSettingsKeys.all.contains("libraryGroupsByDate"))
    }

    @Test("a key outside the allowlist is refused")
    func unknownSettingRefused() async throws {
        let (_, server, context, commands) = try makeRig()
        await #expect(throws: AutomationError.self) {
            _ = try await run(
                commands,
                "setSetting",
                ["key": .string("libraryURL"), "value": .string("/tmp")],
                context
            )
        }
        withExtendedLifetime(server) {}
    }
}
