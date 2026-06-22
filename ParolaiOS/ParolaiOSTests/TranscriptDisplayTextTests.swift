import Foundation
import Testing
@testable import Parola
import ParolaCore

@MainActor
@Suite("Transcript detail display text")
struct TranscriptDisplayTextTests {
    @Test("strips leading and trailing newlines")
    func stripsNewlines() {
        #expect(TranscriptDetailView.displayText("\n\nHello\n\n") == "Hello")
    }

    @Test("strips a mix of leading spaces and newlines")
    func stripsMixedWhitespace() {
        #expect(TranscriptDetailView.displayText(" \nCiao come va?\n ") == "Ciao come va?")
    }

    @Test("keeps already-clean text unchanged")
    func keepsCleanText() {
        #expect(TranscriptDetailView.displayText("Hello") == "Hello")
    }

    @Test("strips surrounding spaces")
    func stripsSpaces() {
        #expect(TranscriptDetailView.displayText("  spaced  ") == "spaced")
    }

    @Test("matches the canonical Transcript.text trim for a single segment")
    func matchesCanonicalTrim() {
        let segment = TranscriptSegment(id: 0, start: 0, end: 1, text: "\nl'altro\n", speaker: nil)
        let transcript = Transcript(segments: [segment], language: "it", modelName: "test")
        #expect(TranscriptDetailView.displayText(segment.text) == transcript.text)
    }
}
