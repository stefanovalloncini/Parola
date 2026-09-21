import Foundation
import Testing
@testable import ParolaCore

@Suite("Favorite segments manifest")
struct FavoriteSegmentsManifestTests {
    @Test("legacy manifests decode with no favorites and empty favorites are not encoded")
    func legacyAndOmit() throws {
        let json = """
        {"version": 2, "createdAt": "2026-05-18T00:00:00Z", "originalAudioName": "x.mp3",
         "modelName": "m", "language": "en", "category": "transcription", "source": "file"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(ParolaDocument.Manifest.self, from: Data(json.utf8))
        #expect(manifest.favoriteSegments.isEmpty)
        let encoded = String(decoding: try JSONEncoder().encode(manifest), as: UTF8.self)
        #expect(!encoded.contains("favoriteSegments"))
    }

    @Test("round-trips favorites sorted and exposes them as a set on the entry")
    func roundTrip() throws {
        var manifest = ParolaDocument.Manifest(originalAudioName: "x.mp3", modelName: "m", language: "en")
        manifest.favoriteSegments = [7, 3, 7]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let round = try decoder.decode(ParolaDocument.Manifest.self, from: try encoder.encode(manifest))
        #expect(round.favoriteSegments == [3, 7])
        let entry = LibraryEntry(id: "e", bundleURL: URL(fileURLWithPath: "/tmp/e.parola"), manifest: round)
        #expect(entry.favoriteSegments == [3, 7])
        #expect(entry.isFavorite(segment: 3))
        #expect(!entry.isFavorite(segment: 4))
    }
}
