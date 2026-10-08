import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Settings pane deep-linking")
struct SettingsPaneRoutingTests {

    private func makeModel(mode: AppBootstrap.Mode, features: Set<ParolaFeature>?) -> AppModel {
        let defaults = temporaryDefaults()
        let library = makeTempLibraryURL("settingsrouting")
        switch mode {
        case .normal:
            return AppModel(skipBootstrap: true, defaults: defaults, libraryURL: library, features: features)
        case .test:
            let bootstrap = AppBootstrap(
                mode: .test,
                library: library,
                defaultsOverride: defaults,
                sideEffects: [],
                filePicker: TestFilePicker(),
                enabledFeaturesOverride: features
            )
            return AppModel(bootstrap: bootstrap)
        }
    }

    private func makeRig(
        mode: AppBootstrap.Mode = .normal,
        features: Set<ParolaFeature>? = nil
    ) throws -> (AppModel, ParolaAutomationServer, AutomationContext, [String: AutomationCommand]) {
        let model = makeModel(mode: mode, features: features)
        let server = try ParolaAutomationServer(model: model)
        let context = AutomationContext(model: model, server: server)
        let commands = Dictionary(uniqueKeysWithValues: server.settingsCommands().map { ($0.name, $0) })
        return (model, server, context, commands)
    }

    private func routeEnum(_ command: AutomationCommand?) -> [String]? {
        guard let arg = command?.args.first(where: { $0.name == "route" }) else { return nil }
        guard case .string(let allowed) = arg.kind else { return nil }
        return allowed
    }

    @Test("openSettings with a pane points SettingsView at that pane")
    func openSettingsTargetsPane() async throws {
        let (model, server, context, commands) = try makeRig()
        #expect(model.settingsPane == "general")

        let command = try #require(commands["openSettings"])
        let args = try command.validate(AutomationArgs(["pane": .string("localModels")]))
        let reply = try await command.handler(args, context)
        withExtendedLifetime(server) {}

        #expect(model.settingsPane == "localModels")
        guard case .object(let fields) = reply else {
            Issue.record("expected an object reply, got \(reply)")
            return
        }
        #expect(fields["visible"] == .bool(true))
    }

    @Test("openSettings refuses a pane this deployment hides instead of silently landing on General")
    func openSettingsRefusesGatedPane() async throws {
        let (model, server, context, commands) = try makeRig(features: [.batch])
        #expect(!SettingsRoute.dictation.isVisible(features: model.features))

        let command = try #require(commands["openSettings"])
        let args = try command.validate(AutomationArgs(["pane": .string("dictation")]))
        let reply = try await command.handler(args, context)
        withExtendedLifetime(server) {}

        #expect(model.settingsPane == "general")
        guard case .object(let fields) = reply else {
            Issue.record("expected an object reply, got \(reply)")
            return
        }
        #expect(fields["visible"] == .bool(false))
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

    @Test("test mode: setRoute settings renders the Settings preview in the main window")
    func setRouteSettingsEnablesPreviewInTestMode() async throws {
        let (model, server, context, commands) = try makeRig(mode: .test)
        #expect(model.settingsRoutePreview == false)

        let command = try #require(commands["setRoute"])
        let args = try command.validate(AutomationArgs(["route": .string("settings")]))
        _ = try await command.handler(args, context)
        withExtendedLifetime(server) {}

        #expect(model.settingsRoutePreview == true)
    }

    @Test("test mode: setRoute settings with a pane opens the preview on that pane")
    func setRouteSettingsPicksThePane() async throws {
        let (model, server, context, commands) = try makeRig(mode: .test)
        let command = try #require(commands["setRoute"])
        let args = try command.validate(AutomationArgs(["route": .string("settings"), "pane": .string("dictation")]))
        let reply = try await command.handler(args, context)
        withExtendedLifetime(server) {}

        #expect(model.settingsRoutePreview)
        #expect(model.settingsPane == "dictation")
        guard case .object(let fields) = reply else {
            Issue.record("expected an object reply, got \(reply)")
            return
        }
        #expect(fields["pane"] == .string("dictation"))
    }

    @Test("test mode: setRoute settings refuses an unknown or hidden pane and keeps the current one")
    func setRouteSettingsRefusesABadPane() async throws {
        let (model, server, context, commands) = try makeRig(mode: .test, features: [.batch])
        let command = try #require(commands["setRoute"])
        for pane in ["nonsense-pane", "dictation"] {
            let args = try command.validate(AutomationArgs(["route": .string("settings"), "pane": .string(pane)]))
            do {
                _ = try await command.handler(args, context)
                Issue.record("\(pane) was accepted")
            } catch {
                #expect(error is AutomationError, "\(error)")
            }
        }
        withExtendedLifetime(server) {}
        #expect(model.settingsPane == "general")
    }

    @Test("a pane only goes with the settings route")
    func setRoutePaneNeedsTheSettingsRoute() async throws {
        let (model, server, context, commands) = try makeRig(mode: .test)
        let command = try #require(commands["setRoute"])
        let args = try command.validate(AutomationArgs(["route": .string("queue"), "pane": .string("dictation")]))
        do {
            _ = try await command.handler(args, context)
            Issue.record("a pane was taken with the queue route")
        } catch {
            #expect(error is AutomationError, "\(error)")
        }
        withExtendedLifetime(server) {}
        #expect(model.settingsPane == "general")
    }

    @Test("test mode: switching to a real route clears the Settings preview")
    func setRouteRealRouteClearsPreview() async throws {
        let (model, server, context, commands) = try makeRig(mode: .test)
        model.settingsRoutePreview = true

        let command = try #require(commands["setRoute"])
        let args = try command.validate(AutomationArgs(["route": .string("transcript")]))
        _ = try await command.handler(args, context)
        withExtendedLifetime(server) {}

        #expect(model.settingsRoutePreview == false)
        #expect(model.route == .transcript)
    }

    @Test("release build: setRoute rejects the settings route")
    func setRouteSettingsRejectedInProduction() throws {
        let (_, server, _, commands) = try makeRig(mode: .normal)
        let command = try #require(commands["setRoute"])

        #expect(throws: AutomationError.self) {
            _ = try command.validate(AutomationArgs(["route": .string("settings")]))
        }
        withExtendedLifetime(server) {}
    }

    @Test("settings route and its pane are advertised only in test mode")
    func settingsRouteAdvertisedOnlyInTestMode() throws {
        let prod = try makeRig(mode: .normal).3["setRoute"]
        let test = try makeRig(mode: .test).3["setRoute"]
        #expect(routeEnum(prod)?.isEmpty == false)
        #expect(routeEnum(prod)?.contains("settings") == false)
        #expect(routeEnum(test)?.contains("settings") == true)
        let prodTakesPane = prod?.args.contains { $0.name == "pane" }
        let testTakesPane = test?.args.contains { $0.name == "pane" }
        #expect(prodTakesPane == false)
        #expect(testTakesPane == true)
    }
}
