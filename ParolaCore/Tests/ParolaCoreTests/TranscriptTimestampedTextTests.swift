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

    @Test("uses H:MM:SS when an over-an-hour segment isn't last in the array")
    func hourFormatOutOfOrder() {
        let text = TranscriptTimestampedText.render(transcript(
            [(1, 3700, 3702, "Late", nil), (2, 10, 12, "Early", nil)]
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

    @Test("drops a segment whose text trims to empty")
    func dropsEmptySegment() {
        let text = TranscriptTimestampedText.render(transcript(
            [(1, 0, 2, "Hello", nil), (2, 5, 7, "   ", nil), (3, 90, 95, "World", nil)]
        ))
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("00:00"))
        #expect(lines[1].hasPrefix("01:30"))
        #expect(!text.contains("00:05"))
    }

    @Test("drops a speaker-tagged segment whose text trims to empty")
    func dropsEmptySpeakerSegment() {
        let text = TranscriptTimestampedText.render(transcript(
            [(1, 0, 2, "Hi", "Alice"), (2, 5, 7, "  ", "Bob")]
        ))
        #expect(text.contains("Alice"))
        #expect(!text.contains("Bob"))
        #expect(text.split(separator: "\n").count == 1)
    }

    @Test("omits a whitespace-only speaker label")
    func whitespaceOnlySpeaker() {
        let text = TranscriptTimestampedText.render(transcript(
            [(1, 0, 2, "Hello", "   ")]
        ))
        #expect(text == "00:00  Hello")
    }

    @Test("flattens a newline-bearing speaker onto one line")
    func newlineSpeaker() {
        let text = TranscriptTimestampedText.render(transcript(
            [(1, 0, 2, "Hello", "Marco\nRossi")]
        ))
        #expect(text == "00:00  Marco Rossi: Hello")
        #expect(!text.contains("\n"))
    }

    @Test("trims a padded speaker label")
    func paddedSpeaker() {
        let text = TranscriptTimestampedText.render(transcript(
            [(1, 0, 2, "Hello", " Marco ")]
        ))
        #expect(text == "00:00  Marco: Hello")
    }
}
