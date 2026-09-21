import Foundation
import Testing
@testable import ParolaCore

@Suite("Card metadata manifest fields")
struct CardMetadataManifestTests {
    @Test("defaults are nil and a legacy manifest decodes without them")
    func legacyDecode() throws {
        let json = """
        {"version": 2, "createdAt": "2026-05-18T00:00:00Z", "originalAudioName": "x.mp3",
         "modelName": "m", "language": "en", "category": "transcription", "source": "file"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(ParolaDocument.Manifest.self, from: Data(json.utf8))
        #expect(manifest.aiTitle == nil)
        #expect(manifest.shortSummary == nil)
    }

    @Test("round-trips both fields and omits them when nil")
    func roundTrip() throws {
        var manifest = ParolaDocument.Manifest(originalAudioName: "x.mp3", modelName: "m", language: "it")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let bare = String(decoding: try encoder.encode(manifest), as: UTF8.self)
        #expect(!bare.contains("aiTitle") && !bare.contains("shortSummary"))
        manifest.aiTitle = "Riunione fornitori"
        manifest.shortSummary = "Distinta base e ordini al magazzino per i sensori."
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let round = try decoder.decode(ParolaDocument.Manifest.self, from: try encoder.encode(manifest))
        #expect(round.aiTitle == "Riunione fornitori")
        #expect(round.shortSummary == "Distinta base e ordini al magazzino per i sensori.")
        let entry = LibraryEntry(id: "e", bundleURL: URL(fileURLWithPath: "/tmp/e.parola"), manifest: round)
        #expect(entry.aiTitle == "Riunione fornitori")
        #expect(entry.title == "x")
    }
}
