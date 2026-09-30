import Foundation
import Testing
@testable import ParolaCore

@Suite("Take markers")
struct TakeMarkerFavoriteTests {
    private let segments = [
        TranscriptSegment(id: 0, start: 0, end: 4, text: "Hello"),
        TranscriptSegment(id: 1, start: 4, end: 9, text: "The launch is on the 14th"),
        TranscriptSegment(id: 2, start: 11, end: 15, text: "Thanks"),
    ]

    @Test("a marker favourites the sentence it fell in, or the next one after a gap")
    func mapping() {
        #expect(TakeMarkers.favoriteSegmentIDs(markers: [5.5], segments: segments) == [1])
        #expect(TakeMarkers.favoriteSegmentIDs(markers: [10], segments: segments) == [2])
        #expect(TakeMarkers.favoriteSegmentIDs(markers: [5, 6, 30], segments: segments) == [1])
    }

    @Test("a segment starts at its own start, and a blank one is never picked")
    func boundariesAndBlanks() {
        #expect(TakeMarkers.favoriteSegmentIDs(markers: [4], segments: segments) == [1])
        let withBlank = [
            TranscriptSegment(id: 0, start: 0, end: 2, text: "  "),
            TranscriptSegment(id: 1, start: 2, end: 5, text: "Spoken"),
        ]
        #expect(TakeMarkers.favoriteSegmentIDs(markers: [1], segments: withBlank) == [1])
        #expect(TakeMarkers.favoriteSegmentIDs(markers: [], segments: segments).isEmpty)
    }

    @Test("a manifest written before markers decodes with none, and none are written when there are none")
    func legacyAndOmitted() throws {
        let json = """
        {"version": 2, "createdAt": "2026-05-18T00:00:00Z", "originalAudioName": "x.wav",
         "modelName": "m", "language": "en", "category": "transcription", "source": "microphone"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(ParolaDocument.Manifest.self, from: Data(json.utf8))
        #expect(manifest.takeMarkers == nil)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let bare = String(decoding: try encoder.encode(manifest), as: UTF8.self)
        #expect(!bare.contains("takeMarkers"))

        var marked = manifest
        marked.takeMarkers = [1.5, 42]
        let round = try decoder.decode(ParolaDocument.Manifest.self, from: try encoder.encode(marked))
        #expect(round.takeMarkers == [1.5, 42])
    }

    @Test("an entry saved with markers keeps them and starts with their segments favourited")
    func addKeepsMarkers() async throws {
        try await withStore { store in
            let transcript = Transcript(segments: segments, language: "en", modelName: "tiny")

            let entry = try await store.add(transcript: transcript, audioSource: nil, takeMarkers: [1.2, 10])

            #expect(entry.manifest.takeMarkers == [1.2, 10])
            #expect(entry.favoriteSegments == [0, 2])
            let listed = try #require(await store.list().first)
            #expect(listed.favoriteSegments == [0, 2])
        }
    }

    @Test("an untranscribed take keeps its markers, and its first transcript favourites them in place of what it had")
    func markersOutliveAnUntranscribedSave() async throws {
        try await withStore { store in
            let untranscribed = Transcript(segments: [], language: "en", modelName: "")
            let entry = try await store.add(transcript: untranscribed, audioSource: nil, takeMarkers: [5.5])
            #expect(entry.favoriteSegments.isEmpty)
            #expect(entry.manifest.takeMarkers == [5.5])
            try await store.setFavoriteSegments([2], for: entry.id)

            let refavoured = try await store.replaceFavoritesWithTakeMarkers(in: segments, for: entry.id)

            #expect(refavoured.favoriteSegments == [1])
            #expect(try await store.load(entry.id).entry.favoriteSegments == [1])
        }
    }

    @Test("an entry with no markers comes out of a re-run with no favourites")
    func noMarkersClearsFavourites() async throws {
        try await withStore { store in
            let transcript = Transcript(segments: segments, language: "en", modelName: "tiny")
            let entry = try await store.add(transcript: transcript, audioSource: nil)
            try await store.setFavoriteSegments([0, 2], for: entry.id)

            let rerun = try await store.replaceFavoritesWithTakeMarkers(in: segments, for: entry.id)

            #expect(rerun.favoriteSegments.isEmpty)
            #expect(rerun.manifest.takeMarkers == nil)
        }
    }

    private func withStore(_ body: (LibraryStore) async throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-take-markers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try await body(LibraryStore(libraryURL: folder, extraIndexer: nil))
    }
}
