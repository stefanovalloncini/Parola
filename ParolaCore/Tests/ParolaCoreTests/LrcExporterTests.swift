import Foundation
import Testing
@testable import ParolaCore

@Suite("LRC exporter")
struct LrcExporterTests {
    @Test("one [mm:ss.xx] line per segment")
    func lines() throws {
        let transcript = Transcript(
            segments: [
                TranscriptSegment(id: 0, start: 0.0, end: 1.5, text: "Hello world."),
                TranscriptSegment(id: 1, start: 1.5, end: 4.0, text: " This is Parola."),
                TranscriptSegment(id: 2, start: 4.0, end: 7.25, text: " Goodbye."),
            ],
            language: "en",
            modelName: "x"
        )
        let out = try LrcExporter().renderText(transcript)
        #expect(out == "[00:00.00]Hello world.\n[00:01.50]This is Parola.\n[00:04.00]Goodbye.\n")
    }

    @Test("timestamps round to centiseconds and carry into the next second")
    func rounding() {
        #expect(LrcExporter.lrcTimestamp(61.999) == "01:02.00")
        #expect(LrcExporter.lrcTimestamp(0.005) == "00:00.01")
        #expect(LrcExporter.lrcTimestamp(59.996) == "01:00.00")
    }

    @Test("minutes keep counting past the hour")
    func longMinutes() {
        #expect(LrcExporter.lrcTimestamp(3725.25) == "62:05.25")
    }

    @Test("negative times clamp to zero")
    func negativeClamped() {
        #expect(LrcExporter.lrcTimestamp(-3) == "00:00.00")
    }

    @Test("segments whose text trims to empty are dropped")
    func emptySegmentDropped() throws {
        let transcript = Transcript(
            segments: [
                TranscriptSegment(id: 0, start: 0, end: 1, text: "Hello."),
                TranscriptSegment(id: 1, start: 1, end: 2, text: "   "),
                TranscriptSegment(id: 2, start: 2, end: 3, text: " \n "),
                TranscriptSegment(id: 3, start: 3, end: 4, text: "World."),
            ],
            language: "en",
            modelName: "x"
        )
        let out = try LrcExporter().renderText(transcript)
        #expect(out == "[00:00.00]Hello.\n[00:03.00]World.\n")
    }

    @Test("a newline inside a segment flattens to a space")
    func multilineFlattened() throws {
        let transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "line one\nline two")],
            language: "en",
            modelName: "x"
        )
        let out = try LrcExporter().renderText(transcript)
        #expect(out == "[00:00.00]line one line two\n")
    }

    @Test("registered in Exporters with the lrc extension")
    func registration() {
        #expect(Exporters.exporter(for: .lrc).format == .lrc)
        #expect(ExportFormat.lrc.fileExtension == "lrc")
    }
}
