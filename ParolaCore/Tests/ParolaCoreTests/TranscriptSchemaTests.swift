import Foundation
import Testing
@testable import ParolaCore

@Suite("Transcript schema")
struct TranscriptSchemaTests {
    @Test("captured v1 transcript decodes without loss")
    func decodeV1Fixture() throws {
        let url = try #require(Bundle.module.url(forResource: "transcript-v1", withExtension: "json"))
        let data = try Data(contentsOf: url)
        let transcript = try JSONDecoder().decode(Transcript.self, from: data)

        #expect(transcript.schemaVersion == 1)
        #expect(transcript.language == "en")
        #expect(transcript.modelName == "openai_whisper-large-v3_turbo")
        #expect(transcript.durationSeconds == 7.42)
        #expect(transcript.segments.count == 2)
        #expect(transcript.segments.first?.words?.count == 5)
        #expect(transcript.summary?.chapters.count == 2)
    }

    @Test("legacy transcript without schemaVersion field defaults to 1")
    func legacyMissingSchemaVersion() throws {
        let url = try #require(Bundle.module.url(forResource: "transcript-legacy", withExtension: "json"))
        let data = try Data(contentsOf: url)
        let transcript = try JSONDecoder().decode(Transcript.self, from: data)

        #expect(transcript.schemaVersion == 1)
        #expect(transcript.segments.first?.text == "Hello, world.")
    }

    @Test("schemaVersion round-trips through Codable")
    func schemaVersionRoundTrips() throws {
        let transcript = Transcript(
            schemaVersion: 1,
            segments: [],
            language: "en",
            modelName: "test"
        )
        let data = try JSONEncoder().encode(transcript)
        let decoded = try JSONDecoder().decode(Transcript.self, from: data)
        #expect(decoded.schemaVersion == 1)
    }
}
