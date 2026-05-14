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
        #expect(loaded.audioURL.lastPathComponent == "audio.wav")
        #expect(try Data(contentsOf: loaded.audioURL) == Data("RIFFfakeaudio".utf8))
    }

    @Test("missing manifest is rejected")
    func missingManifest() throws {
        let scratch = tempDir()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let bundle = scratch.appendingPathComponent("empty.parola")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        #expect(throws: Error.self) { try ParolaDocument.read(at: bundle) }
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

        #expect(throws: Error.self) { try ParolaDocument.read(at: bundle) }
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
}
