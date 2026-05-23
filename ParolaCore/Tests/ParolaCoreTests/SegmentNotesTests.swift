import Foundation
import Testing
@testable import ParolaCore

@Suite("Segment notes manifest")
struct SegmentNotesTests {
    @Test("default segment notes are empty")
    func defaultEmpty() {
        let manifest = ParolaDocument.Manifest(
            originalAudioName: "x.mp3", modelName: "m", language: "en"
        )
        #expect(manifest.segmentNotes.isEmpty)
    }

    @Test("decode tolerates missing segmentNotes key")
    func legacyDecode() throws {
        let json = """
        {
          "version": 1,
          "createdAt": "2026-05-18T00:00:00Z",
          "originalAudioName": "x.mp3",
          "modelName": "m",
          "language": "en",
          "category": "transcription"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(ParolaDocument.Manifest.self, from: json.data(using: .utf8)!)
        #expect(manifest.segmentNotes.isEmpty)
    }

    @Test("encode omits segmentNotes when empty")
    func encodeOmitsEmpty() throws {
        let manifest = ParolaDocument.Manifest(
            originalAudioName: "x.mp3", modelName: "m", language: "en"
        )
        let data = try JSONEncoder().encode(manifest)
        let string = String(data: data, encoding: .utf8) ?? ""
        #expect(string.contains("segmentNotes") == false)
    }

    @Test("encodes and round-trips segment notes")
    func roundTrip() throws {
        let manifest = ParolaDocument.Manifest(
            originalAudioName: "x.mp3", modelName: "m", language: "en",
            segmentNotes: ["3": "Important", "7": "Follow up"]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let round = try decoder.decode(ParolaDocument.Manifest.self, from: data)
        #expect(round.segmentNotes == ["3": "Important", "7": "Follow up"])
    }
}
