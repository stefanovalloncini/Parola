import Foundation
import Testing
@testable import ParolaCore

@Suite("Transcript prompt context")
struct TranscriptPromptContextTests {
    private func transcript(_ segments: [TranscriptSegment]) -> Transcript {
        Transcript(segments: segments, language: "en", modelName: "tiny")
    }

    @Test("renders one timestamped line per segment")
    func timestampedLines() {
        let out = TranscriptPromptContext.timestampedLines(for: transcript([
            TranscriptSegment(id: 0, start: 0, end: 1, text: "Hello"),
            TranscriptSegment(id: 1, start: 65, end: 70, text: "world"),
        ]))
        #expect(out == "00:00  Hello\n01:05  world\n")
    }

    @Test("uses H:MM:SS once a segment passes an hour")
    func longTimestamps() {
        let out = TranscriptPromptContext.timestampedLines(for: transcript([
            TranscriptSegment(id: 0, start: 3700, end: 3760, text: "Late"),
        ]))
        #expect(out == "1:01:40  Late\n")
    }

    @Test("trims surrounding whitespace and newlines so each segment stays one line")
    func trimsToOneLine() {
        let out = TranscriptPromptContext.timestampedLines(for: transcript([
            TranscriptSegment(id: 0, start: 0, end: 1, text: "  hi \n"),
        ]))
        #expect(out == "00:00  hi\n")
    }

    @Test("an empty transcript renders nothing")
    func empty() {
        #expect(TranscriptPromptContext.timestampedLines(for: transcript([])).isEmpty)
    }
}
