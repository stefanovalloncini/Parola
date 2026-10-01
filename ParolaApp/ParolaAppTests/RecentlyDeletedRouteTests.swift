import AppKit
import Foundation
import SwiftUI
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

    private func entry(_ id: String, language: String, deletedAt: Date? = nil) -> LibraryEntry {
        var manifest = ParolaDocument.Manifest(originalAudioName: "\(id).m4a", title: id, modelName: "stub", language: language)
        manifest.deletedAt = deletedAt
        return LibraryEntry(
            id: id,
            bundleURL: URL(fileURLWithPath: "/tmp/RecentlyDeletedRouteTests/\(id).parola"),
            manifest: manifest
        )
    }

    @Test("a row names its language against the library's usual one, and follows it when it changes")
    func rowsFollowTheUsualLanguage() async {
        let model = makeModel()
        await model.libraryRefreshTask?.value
        model.libraryEntries = ["a", "b", "c"].map { entry($0, language: "en") }
        model.setDeletedEntries([entry("trashed", language: "it", deletedAt: Date())])
        model.openRecentlyDeleted()
        let page = HostedWindow(ContentRoutes().environment(model))
        defer { page.close() }
        let italian = LanguageDisplay.name(for: "it") ?? "IT"
        // The row rebuilds once its preview loads, so the library changes only after that.
        let precondition = await waitUntil {
            let words = HostedAccessibility.words(in: page.host)
            return words.contains(italian) && words.contains("No transcript text.")
        }
        #expect(precondition, "the row never named Italian before the change")

        model.libraryEntries = ["a", "b", "c"].map { entry($0, language: "it") }
        let dropped = await waitUntil { !HostedAccessibility.words(in: page.host).contains(italian) }
        #expect(dropped, "Italian is the usual language now, so the row stops naming it")
    }

    @Test("a trashed row's length reads in words to VoiceOver")
    func trashedLengthReadsInWords() async throws {
        let model = makeModel()
        await model.libraryRefreshTask?.value
        var manifest = ParolaDocument.Manifest(originalAudioName: "long.m4a", title: "Long", modelName: "stub", language: "en", durationSeconds: 4_320)
        manifest.deletedAt = Date()
        model.setDeletedEntries([LibraryEntry(id: "long", bundleURL: URL(fileURLWithPath: "/tmp/RecentlyDeletedRouteTests/long.parola"), manifest: manifest)])
        model.openRecentlyDeleted()
        let page = HostedWindow(ContentRoutes().environment(model))
        defer { page.close() }
        let spoken = try #require(LibraryRowFormat.spokenDuration(4_320))
        let heard = await waitUntil { HostedAccessibility.words(in: page.host).contains(spoken) }
        #expect(heard, "\(spoken) was never read")
    }

    @Test("the kind filter is a header chip, as the Library page's filters are")
    func kindFilterIsAHeaderChip() {
        let model = makeModel()
        let header = HostedWindow(RecentlyDeletedHeader(
            categoryFilter: .constant(.all),
            sortOption: .constant(.deletedEarliest),
            confirmingEmpty: .constant(false),
            onRestoreSelection: {},
            onDeleteSelection: {}
        ).environment(model), width: 900, height: 120)
        defer { header.close() }
        let chips = HostedAccessibility.appKitElements(in: header.host).flatMap(\.words)
        #expect(chips.contains("All Kinds"), "\(chips)")
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
        model.personFilter = UUID()

        model.openRecentlyDeleted()

        #expect(model.route == .recentlyDeleted)
        #expect(model.libraryFilter == nil)
        #expect(model.personFilter == nil)
    }

    @Test("closing the page leaves the route and drops what was selected on it")
    func closeLeavesTheRoute() {
        let model = makeModel()
        model.openRecentlyDeleted()
        model.recentlyDeletedSelection = ["a", "b"]

        model.closeRecentlyDeleted()

        #expect(model.route == .transcript)
        #expect(model.recentlyDeletedSelection.isEmpty)
    }

    @Test("leaving by any other route drops the selection too")
    func anyRouteChangeClearsTheSelection() {
        let model = makeModel()
        model.openRecentlyDeleted()
        model.recentlyDeletedSelection = ["a"]

        model.route = .queue

        #expect(model.recentlyDeletedSelection.isEmpty, "setRoute is the bridge's way off the page")
    }

    @Test("a selection lives as long as the page does")
    func selectionSurvivesWhileThePageIsUp() {
        let model = makeModel()
        model.openRecentlyDeleted()
        model.recentlyDeletedSelection = ["a"]

        model.libraryFilter = .meeting

        #expect(model.recentlyDeletedSelection == ["a"], "a filter change is not a route change")
    }

    private func lit(
        _ route: AppModel.Route, searching: Bool = false, filter: EntryCategory? = nil
    ) -> SidebarItem? {
        let page = SidebarSelection.Page(
            route: route, listShowing: route == .transcript, searching: searching, libraryFilter: filter, personFilter: nil
        )
        return SidebarSelection.current(page, sidebarPeople: [], showsActivity: true, showsRecording: false)
    }

    @Test("the sidebar highlights the Recently Deleted row while the page shows")
    func sidebarSelectsTheRow() {
        #expect(lit(.recentlyDeleted) == .recentlyDeleted)
    }

    @Test("no other sidebar row answers to the Recently Deleted route")
    func sidebarRowsAreExclusive() {
        #expect(lit(.recentlyDeleted, searching: true, filter: .meeting) == .recentlyDeleted)
        #expect(lit(.queue) == .activity)
        #expect(lit(.batch) == nil)
        #expect(lit(.transcript) == .library)
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
