import Foundation
import Testing
@testable import Parola
import ParolaCore

@MainActor
@Suite("Settings pane deep-linking")
struct SettingsPaneRoutingTests {

    private func makeRig() throws -> (AppModel, ParolaAutomationServer, AutomationContext, [String: AutomationCommand]) {
        let model = AppModel(skipBootstrap: true, defaults: UserDefaults(suiteName: "test-\(UUID())")!)
        let server = try ParolaAutomationServer(model: model)
        let context = AutomationContext(model: model, server: server)
        let commands = Dictionary(uniqueKeysWithValues: server.settingsCommands().map { ($0.name, $0) })
        return (model, server, context, commands)
    }

    @Test("openSettings with a pane points SettingsView at that pane")
    func openSettingsTargetsPane() async throws {
        let (model, server, context, commands) = try makeRig()
        #expect(model.settingsPane == "general")

        let command = try #require(commands["openSettings"])
        let args = try command.validate(AutomationArgs(["pane": .string("localModels")]))
        _ = try await command.handler(args, context)
        withExtendedLifetime(server) {}

        #expect(model.settingsPane == "localModels")
    }

    @Test("openSettings rejects an unknown pane instead of diverging model state from the UI")
    func openSettingsRejectsUnknownPane() async throws {
        let (model, server, context, commands) = try makeRig()
        let command = try #require(commands["openSettings"])
        let args = try command.validate(AutomationArgs(["pane": .string("nonsense-pane")]))

        await #expect(throws: AutomationError.self) {
            _ = try await command.handler(args, context)
        }
        withExtendedLifetime(server) {}
        #expect(model.settingsPane == "general")
    }

    @Test("openSettings without a pane leaves the current pane untouched")
    func openSettingsKeepsPaneWhenAbsent() async throws {
        let (model, server, context, commands) = try makeRig()
        model.settingsPane = "dictation"

        let command = try #require(commands["openSettings"])
        let args = try command.validate(AutomationArgs())
        _ = try await command.handler(args, context)
        withExtendedLifetime(server) {}

        #expect(model.settingsPane == "dictation")
    }
}
