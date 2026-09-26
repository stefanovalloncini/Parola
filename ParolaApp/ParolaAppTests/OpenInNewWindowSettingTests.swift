import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Open transcripts in a new window", .serialized)
struct OpenInNewWindowSettingTests {

    private func makeRig(
        _ label: String,
        defaults: UserDefaults
    ) -> (model: AppModel, opened: OpenedWindows) {
        let model = AppModel(skipBootstrap: true, defaults: defaults, libraryURL: makeTempLibraryURL(label))
        let opened = OpenedWindows()
        model.bindOpenEntryWindow { opened.ids.append($0) }
        return (model, opened)
    }

    @MainActor
    private final class OpenedWindows {
        var ids: [LibraryEntry.ID] = []
    }

    private func entry(id: String) -> LibraryEntry {
        let manifest = ParolaDocument.Manifest(originalAudioName: "\(id).m4a", modelName: "stub", language: "en")
        return LibraryEntry(
            id: id,
            bundleURL: URL(fileURLWithPath: "/tmp/OpenInNewWindowSettingTests/\(id).parola"),
            manifest: manifest
        )
    }

    @Test("off by default, a double-click loads into the main pane")
    func defaultRoutesToTheMainPane() throws {
        let (model, opened) = makeRig("newwindowoff", defaults: temporaryDefaults())
        model.libraryEntries = [entry(id: "a")]

        #expect(model.openEntriesInNewWindow == false)

        model.openEntryFromLibrary("a", inNewWindow: false)

        #expect(opened.ids.isEmpty)
    }

    @Test("with the setting on, a double-click opens a window and leaves the pane alone")
    func settingRoutesToAWindow() throws {
        let (model, opened) = makeRig("newwindowon", defaults: temporaryDefaults())
        model.libraryEntries = [entry(id: "a")]
        model.openEntriesInNewWindow = true

        model.openEntryFromLibrary("a", inNewWindow: false)

        #expect(opened.ids == ["a"])
        #expect(model.selectedEntryID == nil)
        #expect(model.transcript == nil)
    }

    @Test("holding Option opens a window even with the setting off")
    func optionForcesAWindow() throws {
        let (model, opened) = makeRig("newwindowoption", defaults: temporaryDefaults())
        model.libraryEntries = [entry(id: "a")]

        model.openEntryFromLibrary("a", inNewWindow: true)

        #expect(opened.ids == ["a"])
        #expect(model.selectedEntryID == nil)
    }

    @Test("an entry the library does not hold opens nothing")
    func unknownEntryOpensNothing() throws {
        let (model, opened) = makeRig("newwindowunknown", defaults: temporaryDefaults())
        model.libraryEntries = [entry(id: "a")]

        model.openEntryWindow("b")

        #expect(opened.ids.isEmpty)
    }

    @Test("the setting is read at bootstrap and again on reload")
    func settingLoadsAtBootstrapAndOnReload() throws {
        let defaults = temporaryDefaults()
        defaults.set(true, forKey: "openEntriesInNewWindow")

        let (model, _) = makeRig("newwindowbootstrap", defaults: defaults)
        #expect(model.openEntriesInNewWindow)

        defaults.set(false, forKey: "openEntriesInNewWindow")
        model.reloadSettings()

        #expect(model.openEntriesInNewWindow == false)
    }

    @Test("the toggle writes the key the bridge and the General pane share")
    func togglePersistsUnderTheSharedKey() throws {
        let defaults = temporaryDefaults()
        let (model, _) = makeRig("newwindowkey", defaults: defaults)

        model.openEntriesInNewWindow = true

        #expect(defaults.bool(forKey: "openEntriesInNewWindow"))
        #expect(ParolaAutomationServer.writableSettingKeys.contains("openEntriesInNewWindow"))
        #expect(SettingsPaneScope.general.defaultsKeys.contains("openEntriesInNewWindow"))
    }

    @Test("the bridge opens a window through the same entry point")
    func bridgeOpensAWindow() async throws {
        let defaults = temporaryDefaults()
        let model = AppModel(skipBootstrap: true, defaults: defaults, libraryURL: makeTempLibraryURL("newwindowbridge"))
        let opened = OpenedWindows()
        model.bindOpenEntryWindow { opened.ids.append($0) }
        model.libraryEntries = [entry(id: "a")]
        let server = try ParolaAutomationServer(model: model)
        let context = AutomationContext(model: model, server: server)
        let commands = Dictionary(uniqueKeysWithValues: server.windowCommands().map { ($0.name, $0) })
        let command = try #require(commands["openEntryInNewWindow"])
        let args = try command.validate(AutomationArgs(["entryID": .string("a")]))

        _ = try await command.handler(args, context)
        withExtendedLifetime(server) {}

        #expect(opened.ids == ["a"])
    }

    @Test("the bridge's loadEntry follows the setting")
    func bridgeLoadEntryFollowsTheSetting() async throws {
        let defaults = temporaryDefaults()
        let model = AppModel(skipBootstrap: true, defaults: defaults, libraryURL: makeTempLibraryURL("newwindowbridgeload"))
        let opened = OpenedWindows()
        model.bindOpenEntryWindow { opened.ids.append($0) }
        model.libraryEntries = [entry(id: "a")]
        model.openEntriesInNewWindow = true
        let server = try ParolaAutomationServer(model: model)
        let context = AutomationContext(model: model, server: server)
        let commands = Dictionary(uniqueKeysWithValues: server.libraryCommands().map { ($0.name, $0) })
        let command = try #require(commands["loadEntry"])
        let args = try command.validate(AutomationArgs(["id": .string("a")]))

        _ = try await command.handler(args, context)
        withExtendedLifetime(server) {}

        #expect(opened.ids == ["a"])
        #expect(model.selectedEntryID == nil)
    }

    @Test("getState reports the windows that are open")
    func stateReportsOpenWindows() async throws {
        let model = EntryWindowTestSupport.makeModel("newwindowstate")
        let entry = try await EntryWindowTestSupport.seed(
            model, texts: ["alpha"], speakers: [nil], audio: nil
        )
        let server = try ParolaAutomationServer(model: model)
        _ = model.entryWindowSession(for: entry.id)

        let state = server.snapshotState()
        withExtendedLifetime(server) {}

        guard case .object(let fields) = state,
              case .array(let ids)? = fields["openEntryWindows"] else {
            Issue.record("getState carried no openEntryWindows")
            return
        }
        #expect(ids == [.string(entry.id)])
    }

    @Test("commands that need the main transcript go quiet while a viewer is key")
    func viewerFocusDisablesMainTranscriptCommands() async throws {
        let model = EntryWindowTestSupport.makeModel("newwindowfocus")
        let entry = try await EntryWindowTestSupport.seed(
            model, texts: ["alpha"], speakers: [nil], audio: nil
        )
        model.loadEntry(entry.id)
        await waitUntil(timeoutMs: 3000) { model.hasTranscript }

        #expect(model.mainTranscriptCommandsEnabled)

        model.entryWindowKeyChanged(entry.id, isKey: true)
        #expect(model.keyWindowIsViewer)
        #expect(model.mainTranscriptCommandsEnabled == false)

        model.entryWindowKeyChanged(entry.id, isKey: false)
        #expect(model.keyWindowIsViewer == false)
        #expect(model.mainTranscriptCommandsEnabled)
    }

    @Test("Find follows the key window")
    func findFollowsTheKeyWindow() async throws {
        let model = EntryWindowTestSupport.makeModel("newwindowfind")
        let entry = try await EntryWindowTestSupport.seed(
            model, texts: ["alpha"], speakers: [nil], audio: nil
        )
        model.loadEntry(entry.id)
        await waitUntil(timeoutMs: 3000) { model.hasTranscript }
        let session = await EntryWindowTestSupport.openSession(model, entry)
        model.entryWindowKeyChanged(entry.id, isKey: true)

        model.beginFind()

        #expect(session.searchIsOpen)
        #expect(model.findIsOpen == false)

        let requests = session.searchFocusRequests
        model.beginFind()
        #expect(session.searchIsOpen, "a second ⌘F keeps the viewer's bar open, as in the main window")
        #expect(session.searchFocusRequests == requests &+ 1)

        model.entryWindowKeyChanged(entry.id, isKey: false)
        model.beginFind()

        #expect(model.findIsOpen)
    }
}
