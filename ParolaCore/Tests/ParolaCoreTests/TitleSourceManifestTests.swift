import Foundation
import Testing
@testable import ParolaCore

@Suite("Title source manifest field")
struct TitleSourceManifestTests {
    @Test("a bundle written before the field existed decodes with no title source")
    func legacyDecode() throws {
        let json = """
        {"version": 2, "createdAt": "2026-05-18T00:00:00Z", "originalAudioName": "x.mp3",
         "title": "Recording 18 May 2026 at 09:00", "modelName": "m", "language": "en",
         "category": "transcription", "source": "microphone"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(ParolaDocument.Manifest.self, from: Data(json.utf8))
        #expect(manifest.title == "Recording 18 May 2026 at 09:00")
        #expect(manifest.titleSource == nil)
    }

    @Test("round-trips the field and omits it when nil")
    func roundTrip() throws {
        var manifest = ParolaDocument.Manifest(originalAudioName: "x.mp3", modelName: "m", language: "it")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let bare = String(decoding: try encoder.encode(manifest), as: UTF8.self)
        #expect(!bare.contains("titleSource"))

        manifest.title = "Interview with Marco"
        manifest.titleSource = .user
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let round = try decoder.decode(ParolaDocument.Manifest.self, from: try encoder.encode(manifest))
        #expect(round.title == "Interview with Marco")
        #expect(round.titleSource == .user)

        manifest.titleSource = .source
        let roundSource = try decoder.decode(ParolaDocument.Manifest.self, from: try encoder.encode(manifest))
        #expect(roundSource.titleSource == .source)
    }
}
