import Foundation
import Testing
@testable import ParolaCore

@Suite("Manifest source")
struct ManifestSourceTests {
    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-manifest-source-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func transcript(modelName: String = "openai_whisper-tiny") -> Transcript {
        Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 2, text: "due parole")],
            language: "it",
            modelName: modelName,
            durationSeconds: 2
        )
    }

    private func codecs() -> (JSONEncoder, JSONDecoder) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (encoder, decoder)
    }

    @Test("a bundle records the source it was written with")
    func writeRecordsTheSource() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = try ParolaDocument.write(
            transcript: transcript(), audioURL: nil, to: dir.appendingPathComponent("entry"), entrySource: .web
        )

        #expect(try ParolaDocument.read(at: url).manifest.source == .web)
    }

    @Test("a write that says nothing about the source reads as a file")
    func writeWithoutASourceIsAFile() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = try ParolaDocument.write(
            transcript: transcript(), audioURL: nil, to: dir.appendingPathComponent("entry")
        )

        #expect(try ParolaDocument.read(at: url).manifest.source == .file)
    }

    @Test("every source survives an encode/decode round trip at version 2")
    func sourceRoundTrips() throws {
        let (encoder, decoder) = codecs()
        for source in EntrySource.allCases {
            let manifest = ParolaDocument.Manifest(
                originalAudioName: "a.wav", modelName: "test", language: "en", source: source
            )
            let decoded = try decoder.decode(
                ParolaDocument.Manifest.self, from: try encoder.encode(manifest)
            )

            #expect(decoded.version == 2)
            #expect(decoded.source == source, "\(source)")
        }
    }

    @Test("a manifest written before the field reads as a file")
    func olderManifestDecodesAsAFile() throws {
        let json = """
        {"version":2,"createdAt":"2026-08-22T10:00:00Z","originalAudioName":"a.wav",\
        "modelName":"openai_whisper-tiny","language":"en","category":"transcription"}
        """
        let (_, decoder) = codecs()

        let manifest = try decoder.decode(ParolaDocument.Manifest.self, from: Data(json.utf8))

        #expect(manifest.source == .file)
    }

    /// The captions a fetcher stamps are the one trace of a link an older bundle kept.
    @Test("a manifest written before the field reads subtitle imports as a link", arguments: [
        "youtube-subs", "youtube-auto-subs",
    ])
    func olderCaptionManifestDecodesAsWeb(modelName: String) throws {
        let json = """
        {"version":2,"createdAt":"2026-08-22T10:00:00Z","originalAudioName":"audio.m4a",\
        "modelName":"\(modelName)","language":"en","category":"transcription"}
        """
        let (_, decoder) = codecs()

        let manifest = try decoder.decode(ParolaDocument.Manifest.self, from: Data(json.utf8))

        #expect(manifest.source == .web)
    }

    @Test("the library stamps the source the caller added the entry with")
    func libraryAddCarriesTheSource() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LibraryStore(libraryURL: dir, extraIndexer: nil)

        let entry = try await store.add(
            transcript: transcript(), audioSource: nil, title: "Web video", source: .web
        )

        #expect(entry.manifest.source == .web)
        #expect(try ParolaDocument.read(at: entry.bundleURL).manifest.source == .web)
    }
}
