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

    private func sidebar(_ model: AppModel) -> SidebarItem? {
        SidebarSelection.current(model.sidebarPage, sidebarPeople: [], showsActivity: model.sidebarShowsActivity)
    }

    private func page(
        route: AppModel.Route = .transcript, listShowing: Bool = true, searching: Bool = false,
        filter: EntryCategory? = nil, person: UUID? = nil
    ) -> SidebarSelection.Page {
        .init(route: route, listShowing: listShowing, searching: searching, libraryFilter: filter, personFilter: person)
    }

    // MARK: - The capture rule

    @Test("a search wins over the category filter underneath it")
    func searchBeatsFilter() {
        #expect(LibraryOrigin.capture(from: page(searching: true, filter: .meeting)) == .search)
        #expect(LibraryOrigin.capture(from: page(listShowing: false, searching: true, filter: .meeting)) == .search)
    }

    @Test("a category is recorded as the place the user is in, even under a transcript")
    func categoryList() {
        #expect(LibraryOrigin.capture(from: page(filter: .dictation)) == .category(.dictation))
        #expect(LibraryOrigin.capture(from: page(listShowing: false, filter: .dictation)) == .category(.dictation))
    }

    @Test("the Library page is recorded as the whole library")
    func libraryList() {
        #expect(LibraryOrigin.capture(from: page()) == .all)
    }

    @Test("a person's page is recorded as that person, whether or not the sidebar lists them")
    func personList() {
        let giulia = UUID()
        #expect(LibraryOrigin.capture(from: page(person: giulia)) == .person(giulia))
        #expect(LibraryOrigin.capture(from: page(listShowing: false, person: giulia)) == .person(giulia))
        #expect(LibraryOrigin.capture(from: page(filter: .meeting, person: giulia)) == .category(.meeting), "a person narrowing a category leaves the category the place")
    }

    @Test("an entry opened with no list on screen has no origin")
    func noList() {
        #expect(LibraryOrigin.capture(from: page(listShowing: false)) == nil)
        for route in [AppModel.Route.queue, .batch, .statistics, .recentlyDeleted] {
            let origin = LibraryOrigin.capture(from: page(route: route, searching: true, filter: .meeting))
            #expect(origin == nil, "\(route) is a page of its own, not a list a transcript came from")
        }
    }

    @Test("every origin names itself for the bridge")
    func bridgeNames() {
        #expect(LibraryOrigin.all.bridgeName == "all")
        #expect(LibraryOrigin.category(.meeting).bridgeName == EntryCategory.meeting.rawValue)
        #expect(LibraryOrigin.search.bridgeName == "search")
        #expect(LibraryOrigin.person(UUID()).bridgeName == "person")
    }

    // MARK: - Opening an entry

    @Test("opening from a category records it and leaves the list state standing")
    func opensFromCategory() async throws {
        let model = makeModel()
        let entry = try await seedEntry(in: model, text: "quarterly review", category: .meeting)
        model.browseCategory(.meeting)

        #expect(await openEntry(entry.id, in: model))

        #expect(model.transcriptOrigin == .category(.meeting))
        #expect(model.libraryFilter == .meeting)
        #expect(!model.isBrowsingLibrary, "the transcript takes the content area while it is open")
        #expect(sidebar(model) == nil, "no row is lit over the transcript, so the category row can bring the list back")
    }

    @Test("opening an entry clears a stale failure before the load lands")
    func openingAnEntryClearsAFailure() async throws {
        let model = makeModel()
        let entry = try await seedEntry(in: model, text: "quarterly review")
        model.phase = .failed(message: "Couldn't transcribe Voice note 17.m4a")

        model.loadEntry(entry.id)

        #expect(model.phase == .idle, "the stale failure must not survive the click that starts the open")
        let selectedEntryIDWait = await waitUntil { model.selectedEntryID == entry.id && model.transcript != nil }
        #expect(selectedEntryIDWait)
    }

    @Test("opening from search records the query and keeps the results")
    func opensFromSearch() async throws {
        let model = makeModel()
        let entry = try await seedEntry(in: model, text: "bianchi call")
        model.searchQuery = "bianchi"
        model.searchRanking = [entry.id]

        #expect(await openEntry(entry.id, in: model))

        #expect(model.transcriptOrigin == .search)
        #expect(model.searchRanking == [entry.id])
        #expect(model.searchQuery == "bianchi")
        #expect(sidebar(model) == nil, "no row owns the results or the transcript, so none is highlighted")
    }

    @Test("opening from the Library page records the whole library")
    func opensFromTheLibrary() async throws {
        let model = makeModel()
        let entry = try await seedEntry(in: model, text: "voice memo")

        #expect(await openEntry(entry.id, in: model))

        #expect(model.transcriptOrigin == .all)
        #expect(sidebar(model) == nil, "Library stays clickable over the transcript")
    }

    @Test("opening with a transcript already up and no list leaves no origin")
    func opensWithoutAList() async throws {
        let model = makeModel()
        let first = try await seedEntry(in: model, text: "first")
        let second = try await seedEntry(in: model, text: "second")
        #expect(await openEntry(first.id, in: model))
        model.forgetLibraryOrigin()

        #expect(await openEntry(second.id, in: model))

        #expect(model.transcriptOrigin == nil, "the menu bar extra opens entries with no list behind them")
    }

    @Test("an entry opened while a page is up takes the content area")
    func opensOverAPage() async throws {
        let model = makeModel()
        let entry = try await seedEntry(in: model, text: "voice memo")
        model.openStatistics()

        #expect(await openEntry(entry.id, in: model))

        #expect(model.route == .transcript)
    }

    @Test("a query typed while a page is up shows its results")
    func searchLeavesAPage() async throws {
        let model = makeModel()
        model.openRecentlyDeleted()

        model.search("bianchi")

        #expect(model.route == .transcript)
    }

    @Test("a transcript that arrives another way does not inherit the last entry's origin")
    func documentDoesNotInheritTheOrigin() async throws {
        let model = makeModel()
        let entry = try await seedEntry(in: model, text: "quarterly review", category: .meeting)
        model.browseCategory(.meeting)
        #expect(await openEntry(entry.id, in: model))
        #expect(model.transcriptOrigin == .category(.meeting))

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-origin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = dir.appendingPathComponent("take")
        _ = try ParolaDocument.write(
            transcript: Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "opened from the Finder")],
                language: "en",
                modelName: "stub"
            ),
            audioURL: nil,
            to: base
        )
        await model.openProjectDocument(at: base.appendingPathExtension("parola"))

        #expect(model.transcriptOrigin == nil, "this transcript was never in a list")
        #expect(model.canReturnToOrigin, "the link still shows — reading Library, per B3")

        model.returnToOrigin()

        let transcriptCleared = await waitUntil { model.transcript == nil }
        #expect(transcriptCleared)
        #expect(model.libraryFilter == nil, "no origin means goHome, not the last entry's category")
        #expect(model.isBrowsingLibrary)
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
        #expect(model.transcriptOrigin == nil)
        #expect(sidebar(model) == .category(.meeting))
    }

    @Test("back from a search result shows the results and the query")
    func backToSearch() async throws {
        let model = makeModel()
        let entry = try await seedEntry(in: model, text: "bianchi call")
        model.searchQuery = "bianchi"
        model.searchRanking = [entry.id]
        #expect(await openEntry(entry.id, in: model))

        #expect(await goBack(in: model))

        #expect(model.searchRanking == [entry.id])
        #expect(model.searchQuery == "bianchi")
        #expect(model.isBrowsingLibrary)
        #expect(sidebar(model) == nil)
    }

    @Test("back from a Library entry shows the whole library again")
    func backToTheLibrary() async throws {
        let model = makeModel()
        let entry = try await seedEntry(in: model, text: "standup notes")
        #expect(await openEntry(entry.id, in: model))

        #expect(await goBack(in: model))

        #expect(model.libraryFilter == nil)
        #expect(model.isBrowsingLibrary)
        #expect(sidebar(model) == .library)
    }

    @Test("back from an entry opened on a person's page shows that person's page, and the link names them")
    func backToAPerson() async throws {
        let model = makeModel()
        await model.addPerson(named: "Giulia Rossi")
        let giulia = try #require(model.person(named: "Giulia Rossi"))
        let entry = try await seedEntry(in: model, text: "call with Giulia")
        model.browsePerson(giulia.id)
        #expect(await openEntry(entry.id, in: model))

        #expect(model.transcriptOrigin == .person(giulia.id))
        let name = TranscriptBackCopy.name(for: .person(giulia.id), personName: model.person(id: giulia.id)?.name)
        #expect(name == "Giulia Rossi")
        #expect(TranscriptBackCopy.help(for: .person(giulia.id), personName: "Giulia Rossi") == "Back to Giulia Rossi")

        #expect(await goBack(in: model))

        #expect(model.personFilter == giulia.id)
        #expect(model.libraryFilter == nil)
        #expect(model.isBrowsingLibrary)
        #expect(sidebar(model) == nil, "Giulia has no sidebar row here; her page is still the one on screen")
        #expect(SidebarSelection.place(of: model.sidebarPage) == .person(giulia.id))
    }

    @Test("a person who left the directory sends the link back to the Library's words")
    func personWithoutAName() {
        #expect(TranscriptBackCopy.name(for: .person(UUID()), personName: nil) == "Library")
        #expect(TranscriptBackCopy.help(for: .person(UUID()), personName: nil) == "Back to Library")
    }

    @Test("back from a person deleted while their entry was open lands on the whole library")
    func backFromADeletedPerson() async throws {
        let model = makeModel()
        await model.addPerson(named: "Giulia Rossi")
        let giulia = try #require(model.person(named: "Giulia Rossi"))
        let entry = try await seedEntry(in: model, text: "call with Giulia")
        model.browsePerson(giulia.id)
        #expect(await openEntry(entry.id, in: model))
        #expect(model.transcriptOrigin == .person(giulia.id))

        await model.deletePerson(giulia.id)
        #expect(await goBack(in: model))

        #expect(model.personFilter == nil, "no chip for a person who is gone")
        #expect(model.libraryFilter == nil)
        #expect(model.isBrowsingWholeLibrary)
    }

    @Test("back with no origin falls back to the Library page")
    func backWithoutOrigin() async throws {
        let model = makeModel()
        let entry = try await seedEntry(in: model, text: "opened from the menu bar")
        model.browseCategory(.meeting)
        #expect(await openEntry(entry.id, in: model))
        model.forgetLibraryOrigin()

        #expect(await goBack(in: model))

        #expect(model.libraryFilter == nil)
        #expect(model.isBrowsingLibrary)
        #expect(sidebar(model) == .library)
    }

    @Test("back with no origin leaves a person's list for the whole library")
    func backWithoutOriginLeavesThePerson() async throws {
        let model = makeModel()
        let entry = try await seedEntry(in: model, text: "dropped on a person's list")
        model.browsePerson(UUID())
        #expect(await openEntry(entry.id, in: model))
        model.forgetLibraryOrigin()

        #expect(await goBack(in: model))

        #expect(model.personFilter == nil)
        #expect(model.isBrowsingWholeLibrary)
    }

    @Test("a failure over an open transcript is the Library page to the sidebar, the bridge and ⌘[")
    func failureOverATranscriptIsTheLibraryPage() async throws {
        let model = makeModel()
        let entry = try await seedEntry(in: model, text: "standup notes")
        #expect(await openEntry(entry.id, in: model))

        model.phase = .failed(message: "The file couldn't be decoded.")

        #expect(ContentRoutes.routeID(for: model) == .library)
        #expect(model.isBrowsingLibrary)
        #expect(model.isBrowsingWholeLibrary, "the bridge's libraryBrowsingAll")
        #expect(sidebar(model) == .library)
        #expect(!model.canReturnToOrigin, "no transcript is on screen for ⌘[ to leave")
        #expect(LibraryListContent.showsBrowseList(hasTranscript: model.hasTranscript, failed: true))

        model.dismissError()
        #expect(!model.isBrowsingLibrary, "the transcript comes back once the failure goes")
        #expect(model.canReturnToOrigin)
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
        #expect(model.canReturnToOrigin, "a listed batch stays on its own page")

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

        let transcriptCleared = await waitUntil { model.transcript == nil }
        #expect(transcriptCleared)
        #expect(model.isBrowsingLibrary)
        #expect(model.transcriptOrigin == nil)
    }

    @Test("a person's row takes their list back from a transcript opened off it")
    func personRowLeavesTheTranscript() async throws {
        let model = makeModel()
        let entry = try await seedEntry(in: model, text: "call with Giulia")
        let giulia = UUID()
        model.browsePerson(giulia)
        #expect(await openEntry(entry.id, in: model))
        #expect(SidebarSelection.current(model.sidebarPage, sidebarPeople: [giulia], showsActivity: false) == nil)

        model.browsePerson(giulia)

        let closed = await waitUntil { model.transcript == nil }
        #expect(closed)
        #expect(model.personFilter == giulia)
        #expect(model.isBrowsingLibrary)
        #expect(SidebarSelection.current(model.sidebarPage, sidebarPeople: [giulia], showsActivity: false) == .person(giulia))
    }

    @Test("a sidebar list row retires the search that would mask it")
    func sidebarRowClearsTheSearch() async throws {
        let model = makeModel()
        let entry = try await seedEntry(in: model, text: "bianchi call")
        model.searchQuery = "bianchi"
        model.searchRanking = [entry.id]

        model.browseCategory(.meeting)

        #expect(model.searchRanking == nil)
        #expect(model.searchQuery.isEmpty)
        #expect(sidebar(model) == .category(.meeting))
    }

    // MARK: - Searching over an open transcript

    @Test("results the transcript was opened from wait behind it")
    func ownResultsStayBehind() async throws {
        let model = makeModel()
        let entry = try await seedEntry(in: model, text: "bianchi call")
        model.searchQuery = "bianchi"
        model.searchRanking = [entry.id]

        #expect(await openEntry(entry.id, in: model))

        #expect(!model.isBrowsingLibrary, "the entry opened from these results, so they don't cover it")
        #expect(model.canReturnToOrigin)
    }

    @Test("a new query takes the content area from the open transcript and gives it back")
    func newQueryOverlaysTheTranscript() async throws {
        let model = makeModel()
        let entry = try await seedEntry(in: model, text: "quarterly review", category: .meeting)
        model.browseCategory(.meeting)
        #expect(await openEntry(entry.id, in: model))

        model.search("bianchi")
        model.searchRanking = [entry.id]

        #expect(model.transcriptOrigin == .category(.meeting), "the query cannot take the list away")
        #expect(model.isBrowsingLibrary, "the transcript did not come from these results, so they cover it")
        #expect(!model.canReturnToOrigin, "the results are the page now, not the transcript")

        model.clearSearch()

        #expect(!model.isBrowsingLibrary, "the transcript was parked, not closed")
        #expect(model.transcript != nil)
    }

    @Test("a query that comes and goes over a category entry leaves its origin standing")
    func aQueryDoesNotCostTheCategory() async throws {
        let model = makeModel()
        let entry = try await seedEntry(in: model, text: "quarterly review", category: .meeting)
        model.browseCategory(.meeting)
        #expect(await openEntry(entry.id, in: model))

        model.search("bianchi")
        model.clearSearch()

        #expect(model.transcriptOrigin == .category(.meeting), "the transcript never moved; the query did")
        #expect(model.canReturnToOrigin)
        #expect(sidebar(model) == nil, "the transcript is back on screen, so no row is lit")
    }

    @Test("the same query written again leaves the open transcript where it is")
    func rewritingTheQueryChangesNothing() async throws {
        let model = makeModel()
        let entry = try await seedEntry(in: model, text: "bianchi call")
        model.searchQuery = "bianchi"
        model.searchRanking = [entry.id]
        #expect(await openEntry(entry.id, in: model))

        model.search("bianchi")

        #expect(model.transcriptOrigin == .search)
        #expect(!model.isBrowsingLibrary)
    }

    // MARK: - What the link says

    @Test("the help string names the destination in both languages")
    func helpNamesTheDestination() throws {
        #expect(TranscriptBackCopy.help(for: .category(.meeting)) == "Back to Meetings")
        #expect(TranscriptBackCopy.help(for: .all) == "Back to Library")

        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        let italian = try #require(Bundle(path: path))
        #expect(TranscriptBackCopy.help(for: .category(.meeting), bundle: italian) == "Torna alle riunioni")
        #expect(TranscriptBackCopy.help(for: .search, bundle: italian) == "Torna ai risultati")
        #expect(TranscriptBackCopy.help(for: .all, bundle: italian) == "Torna alla libreria")
        #expect(TranscriptBackCopy.help(for: .person(UUID()), personName: "Giulia Rossi", bundle: italian) == "Torna a Giulia Rossi")
    }

    @Test("the link back to the whole library reads as the sidebar row does")
    func linkNamesTheLibrary() {
        #expect(LibraryOrigin.all.name == "Library")
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

        let transcriptCleared = await waitUntil { model.transcript == nil }
        #expect(transcriptCleared)
        #expect(model.libraryFilter == .meeting)
        guard case .object(let fields) = result else {
            Issue.record("goBack should answer with an object")
            return
        }
        #expect(fields["origin"] == .string("meeting"))
        #expect(fields["route"] == .string("transcript"))
    }

    @Test("an entry the bridge or the menu bar opens over a Meetings entry still goes back to Meetings")
    func openingOverACategoryEntryKeepsThePlace() async throws {
        let (model, server, context, commands) = try makeRig()
        let meeting = try await seedEntry(in: model, text: "quarterly review", category: .meeting)
        let memo = try await seedEntry(in: model, text: "voice memo")
        model.browseCategory(.meeting)
        #expect(await openEntry(meeting.id, in: model))
        let load = try #require(commands["loadEntry"])

        _ = try await load.handler(try load.validate(AutomationArgs(["id": .string(memo.id)])), context)
        withExtendedLifetime(server) {}
        let memoUp = await waitUntil { model.selectedEntryID == memo.id && model.transcript != nil }
        #expect(memoUp)
        #expect(model.transcriptOrigin == .category(.meeting), "the user is still in Meetings, whatever is on screen")

        #expect(await goBack(in: model))

        #expect(model.libraryFilter == .meeting)
        #expect(model.isBrowsingLibrary)
    }

    @Test("goBack from a Library entry replies once the whole library is back")
    func bridgeGoBackToTheLibrary() async throws {
        let (model, server, context, commands) = try makeRig()
        let entry = try await seedEntry(in: model, text: "standup notes")
        #expect(await openEntry(entry.id, in: model))
        let command = try #require(commands["goBack"])

        let result = try await command.handler(try command.validate(AutomationArgs()), context)
        withExtendedLifetime(server) {}

        #expect(model.transcript == nil)
        guard case .object(let fields) = result else {
            Issue.record("goBack should answer with an object")
            return
        }
        #expect(fields["origin"] == .string("all"))
        #expect(fields["libraryBrowsingAll"] == .bool(true))
    }

    @Test("goHome replies once the transcript is gone and the whole library is back")
    func bridgeGoHomeWaitsForTheList() async throws {
        let (model, server, context, commands) = try makeRig()
        let entry = try await seedEntry(in: model, text: "quarterly review", category: .meeting)
        model.browseCategory(.meeting)
        #expect(await openEntry(entry.id, in: model))
        let command = try #require(commands["goHome"])

        let result = try await command.handler(try command.validate(AutomationArgs()), context)
        withExtendedLifetime(server) {}

        #expect(model.transcript == nil, "the reply waited for the transcript to close")
        #expect(model.isBrowsingWholeLibrary)
        #expect(result == .object(["route": .string("transcript")]))
    }

    @Test("getState reports the origin a scenario can assert")
    func bridgeStateCarriesTheOrigin() async throws {
        let (model, server, _, _) = try makeRig()
        let entry = try await seedEntry(in: model, text: "bianchi call")
        model.searchQuery = "bianchi"
        model.searchRanking = [entry.id]
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
