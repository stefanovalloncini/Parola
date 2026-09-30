import AppKit
import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Favorite segments", .serialized)
struct FavoriteSegmentsTests {

    private func makeIsolatedDefaults() -> UserDefaults {
        temporaryDefaults()
    }

    private func makeModel() -> AppModel {
        AppModel(skipBootstrap: true, defaults: makeIsolatedDefaults(), libraryURL: makeTempLibraryURL("favorites"))
    }

    private func threeSegmentTranscript() -> Transcript {
        Transcript(
            segments: [
                TranscriptSegment(id: 0, start: 0, end: 1, text: "first"),
                TranscriptSegment(id: 1, start: 1, end: 2, text: "second"),
                TranscriptSegment(id: 2, start: 2, end: 3, text: "third"),
            ],
            language: "en",
            modelName: "stub"
        )
    }

    private func splittableTranscript() -> Transcript {
        Transcript(
            segments: [
                TranscriptSegment(id: 0, start: 0, end: 2, text: "hello world"),
                TranscriptSegment(id: 1, start: 2, end: 4, text: "second segment"),
            ],
            language: "en",
            modelName: "stub"
        )
    }

    private func loadedModel(_ transcript: Transcript? = nil) async throws -> (AppModel, LibraryEntry.ID) {
        let model = makeModel()
        let seedStore = LibraryStore(libraryURL: model.library.libraryURL, extraIndexer: nil)
        let seeded = try await seedStore.add(
            transcript: transcript ?? threeSegmentTranscript(), audioSource: nil, category: .transcription
        )
        model.loadEntry(seeded.id)
        for _ in 0..<200 where model.selectedEntryID != seeded.id {
            try await Task.sleep(for: .milliseconds(10))
        }
        return (model, seeded.id)
    }

    @Test("toggling a favorite updates the model and persists to the manifest")
    func toggleFavoritePersists() async throws {
        let (model, entryID) = try await loadedModel()

        model.toggleSegmentFavorite(1)
        for _ in 0..<200 where !model.isSegmentFavorite(1) {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(model.isSegmentFavorite(1))
        #expect(await model.library.list().first { $0.id == entryID }?.favoriteSegments == [1])
    }

    @Test("merging keeps the favorite and deleting drops it")
    func mergeAndDeleteRemapFavorites() async throws {
        let (model, _) = try await loadedModel()

        model.toggleSegmentFavorite(1)
        for _ in 0..<200 where !model.isSegmentFavorite(1) {
            try await Task.sleep(for: .milliseconds(10))
        }

        model.mergeSegmentWithNext(id: 0)
        for _ in 0..<200 where model.favoriteSegmentIDs != [0] {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.favoriteSegmentIDs == [0])

        model.deleteSegment(id: 0)
        for _ in 0..<200 where !model.favoriteSegmentIDs.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.favoriteSegmentIDs.isEmpty)
    }

    @Test("copying favorites only puts favorite text on the pasteboard")
    func copyFavoritesOnly() async throws {
        let (model, _) = try await loadedModel()

        model.toggleSegmentFavorite(1)
        for _ in 0..<200 where !model.isSegmentFavorite(1) {
            try await Task.sleep(for: .milliseconds(10))
        }

        // A board of this suite's own: `.general` is shared with every other pasteboard suite
        // running in parallel, and with whoever is running the tests.
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("favorites-test-\(UUID())"))
        model.copyTranscriptToPasteboard(withTimestamps: false, favoritesOnly: true, pasteboard: pasteboard)

        let stringWait = await waitUntil { pasteboard.string(forType: .string) == "second" }
        #expect(stringWait)
    }

    @Test("visibleSegments applies the favorites-only filter")
    func visibleSegmentsFavoritesFilter() {
        let segments = threeSegmentTranscript().segments

        let onlyFavorites = SegmentsScroll.visibleSegments(
            from: segments, speakerFilter: nil, favorites: [1], favoritesOnly: true
        )
        #expect(onlyFavorites.map(\.id) == [1])

        let unfiltered = SegmentsScroll.visibleSegments(
            from: segments, speakerFilter: nil, favorites: [1], favoritesOnly: false
        )
        #expect(unfiltered.map(\.id) == [0, 1, 2])
    }

    @Test("favoritesOnly resets when a new entry loads")
    func favoritesOnlyResetsOnLoadEntry() async throws {
        let (model, _) = try await loadedModel()
        model.favoritesOnly = true

        let seedStore = LibraryStore(libraryURL: model.library.libraryURL, extraIndexer: nil)
        let other = try await seedStore.add(
            transcript: threeSegmentTranscript(), audioSource: nil, category: .transcription
        )
        model.loadEntry(other.id)
        for _ in 0..<200 where model.selectedEntryID != other.id {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(!model.favoritesOnly)
    }

    @Test("favoritesOnly resets when the loaded entry is cleared")
    func favoritesOnlyResetsOnClearLoadedEntry() async throws {
        let (model, _) = try await loadedModel()
        model.favoritesOnly = true

        model.clearLoadedEntry()

        #expect(!model.favoritesOnly)
    }

    @Test("unfavoriting the last favorite turns the filter off")
    func unfavoritingLastFavoriteTurnsOffFilter() async throws {
        let (model, _) = try await loadedModel()

        model.toggleSegmentFavorite(1)
        for _ in 0..<200 where !model.isSegmentFavorite(1) {
            try await Task.sleep(for: .milliseconds(10))
        }
        model.favoritesOnly = true

        model.toggleSegmentFavorite(1)

        // The filter drops inside setSegmentFavorite, which is the single write path both the star
        // and the bridge go through, so it lands on the write's own hop rather than synchronously.
        let favoritesOnlyWait = await waitUntil { !model.favoritesOnly }
        #expect(favoritesOnlyWait)
        let isSegmentFavoriteWait = await waitUntil { !model.isSegmentFavorite(1) }
        #expect(isSegmentFavoriteWait)
    }

    @Test("splitting a favorited segment keeps the favorite on the first half")
    func splitSegmentRemapsFavoriteToFirstHalf() async throws {
        let (model, _) = try await loadedModel(splittableTranscript())

        model.toggleSegmentFavorite(0)
        for _ in 0..<200 where !model.isSegmentFavorite(0) {
            try await Task.sleep(for: .milliseconds(10))
        }

        model.splitSegment(id: 0, atFraction: 0.5)
        let firstHalfID = try #require(model.transcript?.segments.first?.id)
        #expect(firstHalfID != 0)

        for _ in 0..<200 where model.favoriteSegmentIDs != [firstHalfID] {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.favoriteSegmentIDs == [firstHalfID])
    }

    @Test("undo restores the favorite to the original id and redo puts it back on the first half")
    func splitUndoRedoCarriesFavorites() async throws {
        let (model, _) = try await loadedModel(splittableTranscript())
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo

        model.toggleSegmentFavorite(0)
        for _ in 0..<200 where !model.isSegmentFavorite(0) {
            try await Task.sleep(for: .milliseconds(10))
        }

        model.splitSegment(id: 0, atFraction: 0.5)
        let firstHalfID = try #require(model.transcript?.segments.first?.id)
        for _ in 0..<200 where model.favoriteSegmentIDs != [firstHalfID] {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.favoriteSegmentIDs == [firstHalfID])

        undo.undo()
        for _ in 0..<200 where model.favoriteSegmentIDs != [0] {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.favoriteSegmentIDs == [0])
        #expect(model.transcript?.segments.first?.id == 0)

        undo.redo()
        for _ in 0..<200 where model.favoriteSegmentIDs != [firstHalfID] {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.favoriteSegmentIDs == [firstHalfID])
    }
}
