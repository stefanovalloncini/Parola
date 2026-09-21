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

    private func loadedModel() async throws -> (AppModel, LibraryEntry.ID) {
        let model = makeModel()
        let seedStore = LibraryStore(libraryURL: model.library.libraryURL, extraIndexer: nil)
        let seeded = try await seedStore.add(transcript: threeSegmentTranscript(), audioSource: nil, category: .transcription)
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

        NSPasteboard.general.clearContents()
        model.copyTranscriptToPasteboard(withTimestamps: false, favoritesOnly: true)
        var text: String?
        for _ in 0..<200 {
            text = NSPasteboard.general.string(forType: .string)
            if text != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(text == "second")
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
}
