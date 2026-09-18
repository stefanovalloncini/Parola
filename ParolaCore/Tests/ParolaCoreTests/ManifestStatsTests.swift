import Foundation
import Testing
@testable import ParolaCore

@Suite("Manifest timing and word count")
struct ManifestStatsTests {
    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-manifest-stats-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func transcript(timed: Double?) -> Transcript {
        Transcript(
            segments: [
                TranscriptSegment(id: 0, start: 0, end: 2, text: "quattro parole in tutto"),
                TranscriptSegment(id: 1, start: 2, end: 3, text: "cinque"),
            ],
            language: "it",
            modelName: "openai_whisper-tiny",
            durationSeconds: 3,
            transcriptionSeconds: timed
        )
    }

    @Test("a written bundle carries the run's timing and the text's word count")
    func writeRecordsBothFields() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = try ParolaDocument.write(
            transcript: transcript(timed: 12.5), audioURL: nil, to: dir.appendingPathComponent("entry")
        )
        let manifest = try ParolaDocument.read(at: url).manifest

        #expect(manifest.version == 2)
        #expect(manifest.transcriptionSeconds == 12.5)
        #expect(manifest.wordCount == 5)
    }

    @Test("a transcript that was never timed leaves the key out of the manifest")
    func untimedWritesNoKey() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = try ParolaDocument.write(
            transcript: transcript(timed: nil), audioURL: nil, to: dir.appendingPathComponent("entry")
        )
        let json = try String(contentsOf: url.appendingPathComponent("manifest.json"), encoding: .utf8)

        #expect(!json.contains("transcriptionSeconds"))
        #expect(try ParolaDocument.read(at: url).manifest.transcriptionSeconds == nil)
    }

    @Test("a version 2 manifest written before this change decodes with both fields nil")
    func olderManifestDecodes() throws {
        let json = """
        {"version":2,"createdAt":"2026-08-22T10:00:00Z","originalAudioName":"a.wav",\
        "modelName":"test","language":"en","category":"transcription","durationSeconds":60}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(ParolaDocument.Manifest.self, from: Data(json.utf8))

        #expect(manifest.version == 2)
        #expect(manifest.durationSeconds == 60)
        #expect(manifest.transcriptionSeconds == nil)
        #expect(manifest.wordCount == nil)
    }

    @Test("both fields survive an encode/decode round trip at version 2")
    func fieldsRoundTrip() throws {
        var manifest = ParolaDocument.Manifest(
            originalAudioName: "a.wav", modelName: "test", language: "en"
        )
        manifest.transcriptionSeconds = 37.25
        manifest.wordCount = 812

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            ParolaDocument.Manifest.self, from: try encoder.encode(manifest)
        )

        #expect(decoded.version == 2)
        #expect(decoded.transcriptionSeconds == 37.25)
        #expect(decoded.wordCount == 812)
    }

    @Test("an entry reads both facts without opening transcript.json")
    func entryExposesBothFields() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = try ParolaDocument.write(
            transcript: transcript(timed: 9), audioURL: nil, to: dir.appendingPathComponent("entry")
        )
        let entry = LibraryEntry(
            id: "entry", bundleURL: url, manifest: try ParolaDocument.read(at: url).manifest
        )

        #expect(entry.transcriptionSeconds == 9)
        #expect(entry.wordCount == 5)
    }

    @Test("editing a transcript refreshes the stored word count", .tags(.fileSystem))
    func editRefreshesWordCount() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = LibraryStore(libraryURL: dir, extraIndexer: nil)
        let entry = try await store.add(transcript: transcript(timed: 4), audioSource: nil)
        #expect(entry.wordCount == 5)

        var edited = transcript(timed: 4)
        edited.segments[0].text = "due parole"
        try await store.updateTranscript(edited, for: entry.id)

        let reloaded = try #require(await store.list().first { $0.id == entry.id })
        #expect(reloaded.wordCount == 3)
        #expect(reloaded.transcriptionSeconds == 4)
    }
}
