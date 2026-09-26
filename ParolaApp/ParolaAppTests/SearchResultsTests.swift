import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Search results follow the library")
struct SearchResultsTests {

    private func makeModel(_ label: String) -> AppModel {
        AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL(label))
    }

    private func add(_ text: String, to model: AppModel) async throws -> LibraryEntry {
        try await model.library.add(
            transcript: Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: text)],
                language: "en",
                modelName: "stub"
            ),
            audioSource: nil
        )
    }

    private func searchAndWait(_ query: String, in model: AppModel, count: Int) async {
        await model.refreshLibraryAndWait()
        model.search(query)
        await waitUntil { model.searchResults?.count == count }
    }

    @Test("a deleted result leaves the results", .timeLimit(.minutes(1)))
    func deletedResultDisappears() async throws {
        let model = makeModel("search-delete")
        let kept = try await add("the budget review", to: model)
        let deleted = try await add("another budget call", to: model)
        await searchAndWait("budget", in: model, count: 2)

        model.deleteEntry(deleted.id)

        await waitUntil { model.searchResults?.map(\.id) == [kept.id] }
        #expect(model.searchRanking != nil, "the query stays open")
    }

    @Test("a renamed result shows its new title", .timeLimit(.minutes(1)))
    func renamedResultShowsTheNewTitle() async throws {
        let model = makeModel("search-rename")
        let entry = try await add("the budget review", to: model)
        await searchAndWait("budget", in: model, count: 1)

        model.renameEntry(entry.id, to: "Budget, renamed")

        await waitUntil { model.searchResults?.first?.title == "Budget, renamed" }
    }

    @Test("a restored entry that matches comes back into the results", .timeLimit(.minutes(1)))
    func restoredEntryReturns() async throws {
        let model = makeModel("search-restore")
        let entry = try await add("the budget review", to: model)
        try await model.library.delete(entry.id)
        await searchAndWait("budget", in: model, count: 0)

        model.restoreEntry(entry.id)

        await waitUntil { model.searchResults?.map(\.id) == [entry.id] }
    }

    @Test("an entry in the trash does not open", .timeLimit(.minutes(1)))
    func trashedEntryDoesNotOpen() async throws {
        let model = makeModel("search-trash-open")
        let entry = try await add("the budget review", to: model)
        try await model.library.delete(entry.id)

        await #expect(throws: LibraryStore.LibraryError.self) {
            try await model.openEntry(entry.id)
        }
        #expect(model.selectedEntryID == nil)
        #expect(model.transcript == nil)
    }

    @Test("a viewer window stops reading an entry once it is trashed", .timeLimit(.minutes(1)))
    func viewerStopsOnTrash() async throws {
        let model = makeModel("search-trash-viewer")
        let entry = try await add("the budget review", to: model)
        await model.refreshLibraryAndWait()
        let session = model.entryWindowSession(for: entry.id)
        await session.loadTask?.value
        #expect(session.transcript != nil)

        try await model.library.delete(entry.id)
        await model.refreshLibraryAndWait()
        session.reloadIfEntryChanged()
        await session.loadTask?.value

        #expect(session.loadFailed)
        #expect(session.transcript == nil)
        let loads = session.loadGeneration
        session.reloadIfEntryChanged()
        #expect(session.loadGeneration == loads, "a trashed entry is not re-read on every library change")
    }
}
