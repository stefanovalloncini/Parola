import Foundation
import Testing
@testable import ParolaCore

@Suite("Transcript paragraph rule")
struct TranscriptParagraphRuleTests {
    @Test("a gap of exactly pauseSeconds breaks the paragraph")
    func exactGapBreaks() {
        let breaks = TranscriptParagraphRule.breaksParagraph(
            after: 10,
            start: 10 + TranscriptParagraphRule.pauseSeconds
        )
        #expect(breaks)
    }

    @Test("a smaller gap doesn't break the paragraph")
    func smallerGapDoesNotBreak() {
        let breaks = TranscriptParagraphRule.breaksParagraph(
            after: 10,
            start: 10 + TranscriptParagraphRule.pauseSeconds - 0.01
        )
        #expect(!breaks)
    }

    @Test("a nil previous end doesn't break the paragraph")
    func nilPreviousEndDoesNotBreak() {
        #expect(!TranscriptParagraphRule.breaksParagraph(after: nil, start: 0))
    }

    @Test("keeps a real speaker name")
    func keepsRealSpeaker() {
        #expect(TranscriptParagraphRule.speakerLabel(for: "Alice") == "Alice")
    }

    @Test("treats a nil speaker as no label")
    func nilIsNoLabel() {
        #expect(TranscriptParagraphRule.speakerLabel(for: nil) == nil)
    }

    @Test("treats an empty-string speaker as no label")
    func emptyIsNoLabel() {
        #expect(TranscriptParagraphRule.speakerLabel(for: "") == nil)
    }

    @Test("treats a whitespace-only speaker as no label")
    func whitespaceOnlyIsNoLabel() {
        #expect(TranscriptParagraphRule.speakerLabel(for: "  ") == nil)
    }

    @Test("drops a trailing newline from a padded speaker")
    func trailingNewlineTrimmed() {
        #expect(TranscriptParagraphRule.speakerLabel(for: "Alice\n") == "Alice")
    }

    @Test("trims surrounding whitespace from a padded speaker")
    func surroundingWhitespaceTrimmed() {
        #expect(TranscriptParagraphRule.speakerLabel(for: " Alice ") == "Alice")
    }
}
