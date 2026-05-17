import Foundation
import Testing
@testable import ParolaCore

@Suite(".parola document")
struct ParolaDocumentTests {
    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-doc-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func sampleTranscript() -> Transcript {
        Transcript(
            segments: [
                TranscriptSegment(
                    id: 0, start: 0, end: 1.5,
                    text: "Hello world.",
                    speaker: "Speaker 1",
                    words: [
                        WordTiming(id: "0-0", word: "Hello", start: 0.0, end: 0.5, probability: 0.99),
                        WordTiming(id: "0-1", word: "world", start: 0.6, end: 1.4, probability: 0.97),
                    ]
                ),
                TranscriptSegment(id: 1, start: 1.5, end: 3, text: "From Parola.", speaker: "Speaker 2"),
            ],
            language: "en",
            modelName: "openai_whisper-tiny",
            sourceURL: URL(fileURLWithPath: "/tmp/sample.wav"),
            durationSeconds: 3
        )
    }

    @Test("round-trip preserves transcript, manifest, and audio")
    func roundTrip() throws {
        let scratch = tempDir()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let fakeAudio = scratch.appendingPathComponent("clip.wav")
        try Data("RIFFfakeaudio".utf8).write(to: fakeAudio)

        let dest = scratch.appendingPathComponent("project")
        let bundleURL = try ParolaDocument.write(
            transcript: sampleTranscript(),
            audioURL: fakeAudio,
            to: dest
        )
        #expect(bundleURL.pathExtension == "parola")

        let loaded = try ParolaDocument.read(at: bundleURL)
        #expect(loaded.transcript == sampleTranscript())
        #expect(loaded.manifest.originalAudioName == "clip.wav")
        #expect(loaded.manifest.modelName == "openai_whisper-tiny")
        #expect(loaded.manifest.language == "en")
        #expect(loaded.audioURL?.lastPathComponent == "audio.wav")
        if let audioURL = loaded.audioURL {
            #expect(try Data(contentsOf: audioURL) == Data("RIFFfakeaudio".utf8))
        }
    }

    @Test("transcript-only round-trip leaves audioURL nil")
    func transcriptOnlyRoundTrip() throws {
        let scratch = tempDir()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let dest = scratch.appendingPathComponent("notes")
        let bundleURL = try ParolaDocument.write(
            transcript: sampleTranscript(),
            audioURL: nil,
            to: dest
        )

        let loaded = try ParolaDocument.read(at: bundleURL)
        #expect(loaded.audioURL == nil)
        #expect(loaded.manifest.originalAudioName == "")
        #expect(loaded.transcript == sampleTranscript())
    }

    @Test("missing manifest is rejected")
    func missingManifest() throws {
        let scratch = tempDir()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let bundle = scratch.appendingPathComponent("empty.parola")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        #expect(throws: ParolaError.self) { try ParolaDocument.read(at: bundle) }
    }

    @Test("missing audio file no longer throws")
    func missingAudioReadsAsNil() throws {
        let scratch = tempDir()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let bundle = scratch.appendingPathComponent("no-audio.parola")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let manifest = """
        { "version": 1, "createdAt": "2030-01-01T00:00:00Z", "originalAudioName": "", "modelName": "x", "language": "en" }
        """
        try Data(manifest.utf8).write(to: bundle.appendingPathComponent("manifest.json"))
        let transcript = """
        { "segments": [], "language": "en", "modelName": "x" }
        """
        try Data(transcript.utf8).write(to: bundle.appendingPathComponent("transcript.json"))

        let loaded = try ParolaDocument.read(at: bundle)
        #expect(loaded.audioURL == nil)
    }

    @Test("newer version is rejected")
    func newerVersion() throws {
        let scratch = tempDir()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let bundle = scratch.appendingPathComponent("future.parola")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)

        // Hand-craft a manifest claiming a much higher version.
        let manifest = """
        { "version": 999, "createdAt": "2030-01-01T00:00:00Z", "originalAudioName": "x.wav", "modelName": "x", "language": "en" }
        """
        try Data(manifest.utf8).write(to: bundle.appendingPathComponent("manifest.json"))
        try Data("{}".utf8).write(to: bundle.appendingPathComponent("transcript.json"))
        try Data("".utf8).write(to: bundle.appendingPathComponent("audio.wav"))

        #expect(throws: ParolaError.self) { try ParolaDocument.read(at: bundle) }
    }

    @Test("destination without extension gets .parola appended")
    func extensionAppended() throws {
        let scratch = tempDir()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let fakeAudio = scratch.appendingPathComponent("clip.wav")
        try Data("x".utf8).write(to: fakeAudio)

        let dest = scratch.appendingPathComponent("no-extension")
        let bundle = try ParolaDocument.write(transcript: sampleTranscript(), audioURL: fakeAudio, to: dest)
        #expect(bundle.lastPathComponent == "no-extension.parola")
    }

    @Test("old manifest decodes with default category and nil deletedAt")
    func oldManifestBackCompat() throws {
        let oldManifest = """
        { "version": 1, "createdAt": "2030-01-01T00:00:00Z", "originalAudioName": "x.wav", "modelName": "x", "language": "en" }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(ParolaDocument.Manifest.self, from: Data(oldManifest.utf8))
        #expect(manifest.category == .transcription)
        #expect(manifest.deletedAt == nil)
    }

    @Test("manifest category and deletedAt survive write and read")
    func categoryAndDeletedAtRoundTrip() throws {
        let scratch = tempDir()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let dest = scratch.appendingPathComponent("meeting")
        let bundleURL = try ParolaDocument.write(
            transcript: sampleTranscript(),
            audioURL: nil,
            to: dest,
            category: .meeting,
            deletedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let loaded = try ParolaDocument.read(at: bundleURL)
        #expect(loaded.manifest.category == .meeting)
        #expect(loaded.manifest.deletedAt == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test("reads bundled tiny.parola fixture", .tags(.fileSystem))
    func bundledFixture() throws {
        let url = try #require(Bundle.module.url(forResource: "tiny", withExtension: "parola"))
        let loaded = try ParolaDocument.read(at: url)
        #expect(loaded.transcript.segments.count == 2)
        #expect(loaded.transcript.segments[0].text == "Hello world.")
        #expect(loaded.transcript.segments[1].text == "Goodbye.")
        #expect(loaded.manifest.modelName == "openai_whisper-tiny")
        #expect(loaded.manifest.language == "en")
        #expect(loaded.manifest.category == .transcription)
        #expect(loaded.audioURL == nil)
    }

    @Test("default write produces transcription category and nil deletedAt")
    func defaultCategory() throws {
        let scratch = tempDir()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let dest = scratch.appendingPathComponent("standard")
        let bundleURL = try ParolaDocument.write(
            transcript: sampleTranscript(),
            audioURL: nil,
            to: dest
        )

        let loaded = try ParolaDocument.read(at: bundleURL)
        #expect(loaded.manifest.category == .transcription)
        #expect(loaded.manifest.deletedAt == nil)
    }
}
