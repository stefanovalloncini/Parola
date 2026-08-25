import Foundation
import Testing
@testable import Parola
import ParolaCore

@MainActor
@Suite("Bridge settings commands")
struct SettingsCommandsTests {

    private func makeRig() throws -> (AppModel, ParolaAutomationServer, AutomationContext, [String: AutomationCommand]) {
        let model = AppModel(
            skipBootstrap: true,
            defaults: UserDefaults(suiteName: "test-\(UUID())")!,
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

    @Test("category 'all' reaches the sidebar's browse-all row")
    func setLibraryFilterAll() async throws {
        let (model, server, context, commands) = try makeRig()
        model.route = .batch

        let result = try await run(commands, "setLibraryFilter", ["category": .string("all")], context)
        withExtendedLifetime(server) {}

        #expect(model.libraryFilter == nil)
        #expect(model.libraryBrowsingAll)
        #expect(model.route == .transcript)
        #expect(result == .object([
            "libraryFilter": .string("all"),
            "libraryBrowsingAll": .bool(true),
        ]))
    }

    @Test("a category filter leaves browse-all behind")
    func setLibraryFilterCategory() async throws {
        let (model, server, context, commands) = try makeRig()
        model.libraryBrowsingAll = true

        _ = try await run(commands, "setLibraryFilter", ["category": .string("meeting")], context)
        withExtendedLifetime(server) {}

        #expect(model.libraryFilter == .meeting)
        #expect(model.libraryBrowsingAll == false)
        #expect(model.route == .transcript)
    }

    @Test("an empty category clears both the filter and browse-all")
    func setLibraryFilterCleared() async throws {
        let (model, server, context, commands) = try makeRig()
        model.libraryFilter = .dictation
        model.libraryBrowsingAll = true

        _ = try await run(commands, "setLibraryFilter", ["category": .string("")], context)
        withExtendedLifetime(server) {}

        #expect(model.libraryFilter == nil)
        #expect(model.libraryBrowsingAll == false)
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
