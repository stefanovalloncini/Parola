import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Recently Deleted route")
struct RecentlyDeletedRouteTests {

    private func makeModel() -> AppModel {
        AppModel(
            skipBootstrap: true,
            defaults: temporaryDefaults(),
            libraryURL: makeTempLibraryURL("recentlydeleted-route")
        )
    }

    private func entry(_ id: String) -> LibraryEntry {
        let manifest = ParolaDocument.Manifest(originalAudioName: "\(id).m4a", modelName: "stub", language: "en")
        return LibraryEntry(
            id: id,
            bundleURL: URL(fileURLWithPath: "/tmp/RecentlyDeletedRouteTests/\(id).parola"),
            manifest: manifest
        )
    }

    private func makeRig() throws -> (AppModel, ParolaAutomationServer, AutomationContext, [String: AutomationCommand]) {
        let model = makeModel()
        let server = try ParolaAutomationServer(model: model)
        let context = AutomationContext(model: model, server: server)
        let commands = Dictionary(uniqueKeysWithValues: server.windowCommands().map { ($0.name, $0) })
        return (model, server, context, commands)
    }

    @Test("opening the page routes to it and leaves the library filters behind")
    func openSelectsTheRoute() {
        let model = makeModel()
        model.libraryFilter = .meeting
        model.libraryBrowsingAll = true

        model.openRecentlyDeleted()

        #expect(model.route == .recentlyDeleted)
        #expect(model.libraryFilter == nil)
        #expect(!model.libraryBrowsingAll)
    }

    @Test("closing the page leaves the route")
    func closeLeavesTheRoute() {
        let model = makeModel()
        model.openRecentlyDeleted()

        model.closeRecentlyDeleted()

        #expect(model.route == .transcript)
    }

    @Test("the sidebar highlights the Recently Deleted row while the page shows")
    func sidebarSelectsTheRow() {
        #expect(
            SidebarRoute.selected(route: .recentlyDeleted, searching: false, filter: nil, browsingAll: false)
                == .recentlyDeleted
        )
    }

    @Test("no other sidebar row answers to the Recently Deleted route")
    func sidebarRowsAreExclusive() {
        let selected = SidebarRoute.selected(route: .recentlyDeleted, searching: true, filter: .meeting, browsingAll: true)
        #expect(selected == .recentlyDeleted)
        #expect(SidebarRoute.selected(route: .queue, searching: false, filter: nil, browsingAll: false) == .queue)
        #expect(SidebarRoute.selected(route: .batch, searching: false, filter: nil, browsingAll: false) == .batch)
        #expect(SidebarRoute.selected(route: .transcript, searching: false, filter: nil, browsingAll: false) == .home)
    }

    @Test("the bridge opens the page by setting the route")
    func bridgeOpens() async throws {
        let (model, server, context, commands) = try makeRig()
        let command = try #require(commands["openRecentlyDeleted"])

        let result = try await command.handler(try command.validate(AutomationArgs()), context)
        withExtendedLifetime(server) {}

        #expect(model.route == .recentlyDeleted)
        guard case .object(let fields) = result else {
            Issue.record("openRecentlyDeleted should answer with an object")
            return
        }
        #expect(fields["open"] == .bool(true))
        #expect(fields["route"] == .string("recentlyDeleted"))
    }

    @Test("the bridge closes the page by leaving the route")
    func bridgeCloses() async throws {
        let (model, server, context, commands) = try makeRig()
        model.openRecentlyDeleted()
        let command = try #require(commands["closeRecentlyDeleted"])

        let result = try await command.handler(try command.validate(AutomationArgs()), context)
        withExtendedLifetime(server) {}

        #expect(model.route == .transcript)
        guard case .object(let fields) = result else {
            Issue.record("closeRecentlyDeleted should answer with an object")
            return
        }
        #expect(fields["open"] == .bool(false))
        #expect(fields["route"] == .string("transcript"))
    }

    @Test("the bridge selects only rows the page is showing")
    func bridgeSelectsDeletedEntries() async throws {
        let (model, server, context, commands) = try makeRig()
        model.deletedEntries = [entry("a"), entry("b")]
        let command = try #require(commands["selectDeletedEntries"])

        let result = try await command.handler(
            try command.validate(AutomationArgs(["ids": .array([.string("b"), .string("ghost")])])),
            context
        )
        withExtendedLifetime(server) {}

        #expect(model.recentlyDeletedSelection == ["b"])
        guard case .object(let fields) = result else {
            Issue.record("selectDeletedEntries should answer with an object")
            return
        }
        #expect(fields["selected"] == .int(1))
        #expect(fields["ids"] == .array([.string("b")]))
    }

    @Test("the bridge clears the selection when it names nothing")
    func bridgeClearsSelection() async throws {
        let (model, server, context, commands) = try makeRig()
        model.deletedEntries = [entry("a")]
        model.recentlyDeletedSelection = ["a"]
        let command = try #require(commands["selectDeletedEntries"])

        _ = try await command.handler(try command.validate(AutomationArgs()), context)
        withExtendedLifetime(server) {}

        #expect(model.recentlyDeletedSelection.isEmpty)
    }

    @Test("setRoute names the page among the routes it accepts")
    func setRouteAcceptsThePage() throws {
        let model = makeModel()
        let server = try ParolaAutomationServer(model: model)
        let command = try #require(server.settingsCommands().first { $0.name == "setRoute" })
        withExtendedLifetime(server) {}

        guard case .string(let options) = command.args.first(where: { $0.name == "route" })?.kind else {
            Issue.record("setRoute should constrain its route argument to an enum")
            return
        }
        #expect(options?.contains("recentlyDeleted") == true)
    }
}
