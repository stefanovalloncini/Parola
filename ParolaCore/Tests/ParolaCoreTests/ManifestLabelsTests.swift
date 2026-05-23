import Foundation
import Testing
@testable import ParolaCore

@Suite("Manifest labels")
struct ManifestLabelsTests {
    @Test("default labels are empty")
    func defaultEmpty() {
        let manifest = ParolaDocument.Manifest(
            originalAudioName: "x.mp3", modelName: "m", language: "en"
        )
        #expect(manifest.labels.isEmpty)
    }

    @Test("decode tolerates missing labels key")
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
        #expect(manifest.labels.isEmpty)
    }

    @Test("encode omits labels when empty to keep legacy bundles clean")
    func encodeOmitsEmpty() throws {
        let manifest = ParolaDocument.Manifest(
            originalAudioName: "x.mp3", modelName: "m", language: "en"
        )
        let data = try JSONEncoder().encode(manifest)
        let string = String(data: data, encoding: .utf8) ?? ""
        #expect(string.contains("labels") == false)
    }

    @Test("encode includes labels when non-empty and round-trips")
    func encodeIncludesLabels() throws {
        let manifest = ParolaDocument.Manifest(
            originalAudioName: "x.mp3", modelName: "m", language: "en",
            labels: ["work", "interview"]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let round = try decoder.decode(ParolaDocument.Manifest.self, from: data)
        #expect(round.labels == ["work", "interview"])
    }
}
