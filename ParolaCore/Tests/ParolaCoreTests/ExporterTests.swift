import Foundation
import Testing
@testable import ParolaCore

@Suite("Exporters")
struct ExporterTests {
    private func sample() -> Transcript {
        Transcript(
            segments: [
                TranscriptSegment(id: 0, start: 0.0, end: 1.5, text: "Hello world."),
                TranscriptSegment(id: 1, start: 1.5, end: 4.0, text: " This is Parola."),
                TranscriptSegment(id: 2, start: 4.0, end: 7.25, text: " Goodbye."),
            ],
            language: "en",
            modelName: "openai_whisper-tiny",
            sourceURL: URL(fileURLWithPath: "/tmp/x.wav"),
            durationSeconds: 7.25
        )
    }

    @Test("txt joins segment lines")
    func txt() throws {
        let out = try TxtExporter().render(sample())
        #expect(out == "Hello world.\nThis is Parola.\nGoodbye.")
    }

    @Test("srt has indexed blocks with comma-millisecond timestamps")
    func srt() throws {
        let out = try SrtExporter().render(sample())
        #expect(out.hasPrefix("1\n00:00:00,000 --> 00:00:01,500\nHello world.\n\n"))
        #expect(out.contains("2\n00:00:01,500 --> 00:00:04,000\nThis is Parola."))
        #expect(out.contains("3\n00:00:04,000 --> 00:00:07,250\nGoodbye."))
    }

    @Test("vtt starts with WEBVTT and uses period millis")
    func vtt() throws {
        let out = try VttExporter().render(sample())
        #expect(out.hasPrefix("WEBVTT\n\n"))
        #expect(out.contains("00:00:00.000 --> 00:00:01.500"))
        #expect(out.contains("00:00:04.000 --> 00:00:07.250"))
    }

    @Test("json round-trips through Codable")
    func json() throws {
        let original = sample()
        let rendered = try JsonExporter().render(original)
        let data = Data(rendered.utf8)
        let decoded = try JSONDecoder().decode(Transcript.self, from: data)
        #expect(decoded == original)
    }

    @Test("srt timestamp formatting")
    func srtTimestamp() {
        #expect(SrtExporter.srtTimestamp(0) == "00:00:00,000")
        #expect(SrtExporter.srtTimestamp(3661.25) == "01:01:01,250")
        #expect(SrtExporter.srtTimestamp(-1) == "00:00:00,000")
    }
}
