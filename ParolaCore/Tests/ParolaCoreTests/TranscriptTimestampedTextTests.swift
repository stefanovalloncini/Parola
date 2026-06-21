import Foundation
import Testing
@testable import ParolaCore

@Suite("Transcript timestamped text")
struct TranscriptTimestampedTextTests {
    private func transcript(_ segments: [(Int, Double, Double, String, String?)]) -> Transcript {
        Transcript(
            schemaVersion: 1,
            segments: segments.map {
                TranscriptSegment(id: $0.0, start: $0.1, end: $0.2, text: $0.3, speaker: $0.4)
            },
            language: "en",
            modelName: "x"
        )
    }

    @Test("prefixes each segment with MM:SS by default")
    func mmssPrefix() {
        let text = TranscriptTimestampedText.render(transcript(
            [(1, 0, 2, "Hello", nil), (2, 90, 95, "World", nil)]
        ))
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines[0].hasPrefix("00:00"))
        #expect(lines[1].hasPrefix("01:30"))
    }

    @Test("includes the speaker when present")
    func includesSpeaker() {
        let text = TranscriptTimestampedText.render(transcript(
            [(1, 0, 2, "Hello", "Alice")]
        ))
        #expect(text.contains("Alice"))
        #expect(text.contains("Hello"))
    }

    @Test("uses H:MM:SS when transcript spans an hour or more")
    func hourFormat() {
        let text = TranscriptTimestampedText.render(transcript(
            [(1, 0, 2, "Open", nil), (2, 3700, 3702, "Close", nil)]
        ))
        #expect(text.contains("1:01:40"))
    }

    @Test("empty transcript returns empty string")
    func emptyTranscript() {
        let text = TranscriptTimestampedText.render(transcript([]))
        #expect(text.isEmpty)
    }

    @Test("renders a huge segment start without trapping")
    func hugeStartDoesNotTrap() {
        let text = TranscriptTimestampedText.render(transcript(
            [(1, 1e19, 1e19, "Boom", nil)]
        ))
        #expect(text.contains("Boom"))
        #expect(!text.isEmpty)
    }

    @Test("trims whitespace inside each segment body")
    func trimsBody() {
        let text = TranscriptTimestampedText.render(transcript(
            [(1, 0, 2, "  hello  ", nil)]
        ))
        #expect(text.hasSuffix("hello"))
    }
}
