import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Library origin")
struct LibraryOriginTests {

    private func makeModel() -> AppModel {
        AppModel(
            skipBootstrap: true,
            defaults: temporaryDefaults(),
            libraryURL: makeTempLibraryURL("library-origin")
        )
    }

    private func seedEntry(in model: AppModel, text: String, category: EntryCategory = .transcription) async throws -> LibraryEntry {
        let seed = LibraryStore(libraryURL: model.library.libraryURL, extraIndexer: nil)
        return try await seed.add(
            transcript: Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: text)],
                language: "en",
                modelName: "stub"
            ),
            audioSource: nil,
            category: category
        )
    }

    private func waitUntil(timeoutMs: Int = 10_000, _ condition: @MainActor () -> Bool) async -> Bool {
        var elapsed = 0
        while elapsed < timeoutMs {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(15))
            elapsed += 15
        }
        return condition()
    }

    private func openEntry(_ id: LibraryEntry.ID, in model: AppModel) async -> Bool {
        model.loadEntry(id)
        return await waitUntil { model.selectedEntryID == id && model.transcript != nil }
    }

    private func goBack(in model: AppModel) async -> Bool {
        model.returnToOrigin()
        return await waitUntil { model.transcript == nil }
    }

    private func sidebar(_ model: AppModel) -> SidebarRoute {
        SidebarRoute.selected(
            route: model.route,
            searching: model.searchResults != nil,
            filter: model.libraryFilter,
            browsingAll: model.libraryBrowsingAll
        )
    }

    // MARK: - The capture rule

    @Test("a search wins over the category filter underneath it")
    func searchBeatsFilter() {
        let origin = LibraryOrigin.capture(
            sidebar: SidebarRoute.selected(route: .transcript, searching: true, filter: .meeting, browsingAll: true),
            query: "bianchi",
            homeOnScreen: false
        )
        #expect(origin == .search(query: "bianchi"))
    }

    @Test("a category list is recorded as its category")
    func categoryList() {
        let origin = LibraryOrigin.capture(
            sidebar: SidebarRoute.selected(route: .transcript, searching: false, filter: .dictation, browsingAll: false),
            query: "",
            homeOnScreen: false
        )
        #expect(origin == .category(.dictation))
    }

    @Test("the flat All list is recorded as All")
    func allList() {
        let origin = LibraryOrigin.capture(
            sidebar: SidebarRoute.selected(route: .transcript, searching: false, filter: nil, browsingAll: true),
            query: "",
            homeOnScreen: false
        )
        #expect(origin == .all)
    }

    @Test("Home's Recent list is recorded as Home")
    func homeRecent() {
        let origin = LibraryOrigin.capture(
            sidebar: SidebarRoute.selected(route: .transcript, searching: false, filter: nil, browsingAll: false),
            query: "",
            homeOnScreen: true
        )
        #expect(origin == .home)
    }

    @Test("an entry opened with no list on screen has no origin")
    func noList() {
        let noHome = LibraryOrigin.capture(
            sidebar: SidebarRoute.selected(route: .transcript, searching: false, filter: nil, browsingAll: false),
            query: "",
            homeOnScreen: false
        )
        #expect(noHome == nil)
        for route in [AppModel.Route.queue, .batch, .recentlyDeleted] {
            let origin = LibraryOrigin.capture(
                sidebar: SidebarRoute.selected(route: route, searching: true, filter: .meeting, browsingAll: true),
                query: "q",
                homeOnScreen: true
            )
            #expect(origin == nil, "\(route) is a page of its own, not a list a transcript came from")
        }
    }

    @Test("every origin names itself for the bridge")
    func bridgeNames() {
        #expect(LibraryOrigin.home.bridgeName == "home")
        #expect(LibraryOrigin.all.bridgeName == "all")
        #expect(LibraryOrigin.category(.meeting).bridgeName == EntryCategory.meeting.rawValue)
        #expect(LibraryOrigin.search(query: "x").bridgeName == "search")
    }

    // MARK: - Opening an entry

    @Test("opening from a category records it and leaves the list state standing")
    func opensFromCategory() async throws {
        let model = makeModel()
        let entry = try await seedEntry(in: model, text: "quarterly review", category: .meeting)
        model.browseCategory(.meeting)

        #expect(await openEntry(entry.id, in: model))

        #expect(model.libraryOrigin == .category(.meeting))
        #expect(model.libraryFilter == .meeting)
        #expect(!model.isBrowsingLibrary, "the transcript takes the content area while it is open")
        #expect(sidebar(model) == .category(.meeting), "the sidebar keeps the row the entry came from")
    }

    @Test("opening from search records the query and keeps the results")
    func opensFromSearch() async throws {
        let model = makeModel()
        let entry = try await seedEntry(in: model, text: "bianchi call")
        model.searchQuery = "bianchi"
        model.searchResults = [entry]

        #expect(await openEntry(entry.id, in: model))

        #expect(model.libraryOrigin == .search(query: "bianchi"))
        #expect(model.searchResults?.map(\.id) == [entry.id])
        #expect(model.searchQuery == "bianchi")
        #expect(sidebar(model) == .search, "no row owns the results, so none is highlighted")
    }

    @Test("opening from Home's Recent list records Home")
    func opensFromHome() async throws {
        let model = makeModel()
        let entry = try await seedEntry(in: model, text: "voice memo")

        #expect(await openEntry(entry.id, in: model))

        #expect(model.libraryOrigin == .home)
        #expect(sidebar(model) == .home)
    }

    @Test("opening with a transcript already up and no list leaves no origin")
    func opensWithoutAList() async throws {
        let model = makeModel()
        let first = try await seedEntry(in: model, text: "first")
        let second = try await seedEntry(in: model, text: "second")
        #expect(await openEntry(first.id, in: model))
        model.libraryOrigin = nil

        #expect(await openEntry(second.id, in: model))

        #expect(model.libraryOrigin == nil, "the menu bar extra opens entries with no list behind them")
    }

    // MARK: - Going back

    @Test("back from a category entry shows that category again")
    func backToCategory() async throws {
        let model = makeModel()
        let entry = try await seedEntry(in: model, text: "quarterly review", category: .meeting)
        model.browseCategory(.meeting)
        #expect(await openEntry(entry.id, in: model))

        #expect(await goBack(in: model))

        #expect(model.libraryFilter == .meeting)
        #expect(model.isBrowsingLibrary)
        #expect(model.selectedEntryID == nil)
        #expect(model.libraryOrigin == nil)
        #expect(sidebar(model) == .category(.meeting))
    }

    @Test("back from a search result shows the results and the query")
    func backToSearch() async throws {
        let model = makeModel()
        let entry = try await seedEntry(in: model, text: "bianchi call")
        model.searchQuery = "bianchi"
        model.searchResults = [entry]
        #expect(await openEntry(entry.id, in: model))

        #expect(await goBack(in: model))

        #expect(model.searchResults?.map(\.id) == [entry.id])
        #expect(model.searchQuery == "bianchi")
        #expect(model.isBrowsingLibrary)
        #expect(sidebar(model) == .search)
    }

    @Test("back from an All entry shows the flat list again")
    func backToAll() async throws {
        let model = makeModel()
        let entry = try await seedEntry(in: model, text: "standup notes")
        model.browseAll()
        #expect(await openEntry(entry.id, in: model))

        #expect(await goBack(in: model))

        #expect(model.libraryBrowsingAll)
        #expect(model.libraryFilter == nil)
        #expect(model.isBrowsingLibrary)
        #expect(sidebar(model) == .all)
    }

    @Test("back from a Recent entry shows Home, not a list")
    func backToHome() async throws {
        let model = makeModel()
        let entry = try await seedEntry(in: model, text: "voice memo")
        #expect(await openEntry(entry.id, in: model))

        #expect(await goBack(in: model))

        #expect(!model.isBrowsingLibrary, "Home is the drop zone and Recent, not a library list")
        #expect(model.libraryFilter == nil)
        #expect(!model.libraryBrowsingAll)
        #expect(sidebar(model) == .home)
    }

    @Test("back with no origin falls back to Home")
    func backWithoutOrigin() async throws {
        let model = makeModel()
        let entry = try await seedEntry(in: model, text: "opened from the menu bar")
        model.browseCategory(.meeting)
        #expect(await openEntry(entry.id, in: model))
        model.libraryOrigin = nil

        #expect(await goBack(in: model))

        #expect(model.libraryFilter == nil)
        #expect(!model.isBrowsingLibrary)
        #expect(sidebar(model) == .home)
    }

    // MARK: - Where the link shows

    @Test("the back link needs a transcript standing on its own")
    func linkVisibility() async throws {
        let model = makeModel()
        #expect(!model.canReturnToOrigin, "nothing is open")

        let entry = try await seedEntry(in: model, text: "standup notes")
        #expect(await openEntry(entry.id, in: model))
        #expect(model.canReturnToOrigin)

        model.batchJobs = [BatchJob(url: URL(fileURLWithPath: "/tmp/library-origin.wav"))]
        #expect(!model.canReturnToOrigin, "the batch list is already beside the transcript")

        model.batchJobs = []
        model.route = .queue
        #expect(!model.canReturnToOrigin, "the transcript is not the page on screen")
    }

    @Test("a sidebar list row leaves the open transcript behind")
    func sidebarRowClosesTheTranscript() async throws {
        let model = makeModel()
        let entry = try await seedEntry(in: model, text: "quarterly review", category: .meeting)
        model.browseCategory(.meeting)
        #expect(await openEntry(entry.id, in: model))

        model.browseAll()

        #expect(await waitUntil { model.transcript == nil })
        #expect(model.isBrowsingLibrary)
        #expect(model.libraryOrigin == nil)
    }

    // MARK: - Bridge

    private func makeRig() throws -> (AppModel, ParolaAutomationServer, AutomationContext, [String: AutomationCommand]) {
        let model = makeModel()
        let server = try ParolaAutomationServer(model: model)
        let context = AutomationContext(model: model, server: server)
        let commands = Dictionary(uniqueKeysWithValues: server.libraryCommands().map { ($0.name, $0) })
        return (model, server, context, commands)
    }

    @Test("goBack returns to the list the entry was opened from")
    func bridgeGoBack() async throws {
        let (model, server, context, commands) = try makeRig()
        let entry = try await seedEntry(in: model, text: "quarterly review", category: .meeting)
        model.browseCategory(.meeting)
        #expect(await openEntry(entry.id, in: model))
        let command = try #require(commands["goBack"])

        let result = try await command.handler(try command.validate(AutomationArgs()), context)
        withExtendedLifetime(server) {}

        #expect(await waitUntil { model.transcript == nil })
        #expect(model.libraryFilter == .meeting)
        guard case .object(let fields) = result else {
            Issue.record("goBack should answer with an object")
            return
        }
        #expect(fields["origin"] == .string("meeting"))
        #expect(fields["route"] == .string("transcript"))
    }

    @Test("getState reports the origin a scenario can assert")
    func bridgeStateCarriesTheOrigin() async throws {
        let (model, server, _, _) = try makeRig()
        let entry = try await seedEntry(in: model, text: "bianchi call")
        model.searchQuery = "bianchi"
        model.searchResults = [entry]
        #expect(await openEntry(entry.id, in: model))

        guard case .object(let fields) = server.snapshotState() else {
            Issue.record("getState should answer with an object")
            return
        }
        #expect(fields["libraryOrigin"] == .string("search"))

        model.goHome()
        guard case .object(let home) = server.snapshotState() else { return }
        #expect(home["libraryOrigin"] == .string(""))
    }
}
