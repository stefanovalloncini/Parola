import Foundation
import Testing
import ParolaCore
@testable import Parola

@MainActor
@Suite("SegmentCard display text")
struct SegmentDisplayTextTests {
    @Test("trims leading and trailing newlines")
    func trimsEdgeNewlines() {
        #expect(SegmentCard.displayText("\n\nHello\n\n") == "Hello")
    }

    @Test("trims leading and trailing spaces")
    func trimsEdgeSpaces() {
        #expect(SegmentCard.displayText("  Hi  ") == "Hi")
    }

    @Test("trims mixed edge whitespace but keeps the inner text")
    func trimsMixedEdges() {
        #expect(SegmentCard.displayText(" \n Hello world \n ") == "Hello world")
    }

    @Test("matches the per-segment trim canonical Transcript.text applies")
    func matchesCanonicalTranscriptText() {
        let segment = TranscriptSegment(id: 0, start: 0, end: 1, text: "\n Hello \n")
        let transcript = Transcript(segments: [segment], language: "en", modelName: "test")
        #expect(transcript.text == SegmentCard.displayText(segment.text))
    }

    @Test("leaves clean text unchanged")
    func cleanTextUnchanged() {
        #expect(SegmentCard.displayText("Hello.") == "Hello.")
    }

    @Test("preserves internal whitespace, trimming edges only")
    func preservesInternalWhitespace() {
        #expect(SegmentCard.displayText("a  b") == "a  b")
    }
}
