import Foundation
import Testing
import ParolaCore
@testable import Parola

@MainActor
@Suite("Continuous paragraph rendering")
struct ContinuousParagraphTests {
    private func segment(_ id: Int, _ text: String, speaker: String? = nil) -> TranscriptSegment {
        TranscriptSegment(id: id, start: Double(id), end: Double(id) + 1, text: text, speaker: speaker)
    }

    private func plainText(_ segments: [TranscriptSegment], useSpeakerColor: Bool = false) -> String {
        String(ContinuousParagraph.paragraph(segments: segments, useSpeakerColor: useSpeakerColor).text.characters)
    }

    @Test("joins segments with a single space and no trailing space")
    func joinsWithSingleSpace() {
        let segments = [segment(0, "Hello."), segment(1, "World.")]
        #expect(plainText(segments) == "Hello. World.")
    }

    @Test("a whitespace-only middle segment does not produce a double space")
    func middleEmptyNoDoubleSpace() {
        let segments = [segment(0, "Hello."), segment(1, "  \n\t "), segment(2, "World.")]
        #expect(plainText(segments) == "Hello. World.")
    }

    @Test("a trailing whitespace-only segment leaves no trailing space")
    func trailingEmptyNoTrailingSpace() {
        let segments = [segment(0, "Hello."), segment(1, "   ")]
        #expect(plainText(segments) == "Hello.")
    }

    @Test("a trailing empty segment after several real ones leaves no trailing space")
    func trailingEmptyAfterManyNoTrailingSpace() {
        let segments = [segment(0, "One"), segment(1, "two"), segment(2, "   ")]
        #expect(plainText(segments) == "One two")
    }

    @Test("a leading whitespace-only segment leaves no leading space")
    func leadingEmptyNoLeadingSpace() {
        let segments = [segment(0, "  "), segment(1, "World.")]
        #expect(plainText(segments) == "World.")
    }

    @Test("rendered text matches the canonical Transcript.text")
    func matchesCanonicalText() {
        let segments = [segment(0, "Hello."), segment(1, "World."), segment(2, "  ")]
        let transcript = Transcript(segments: segments, language: "en", modelName: "test")
        #expect(plainText(segments) == transcript.text)
    }

    @Test("speaker-colored rendering keeps the same plain text")
    func speakerColorPreservesText() {
        let segments = [
            segment(0, "Hi.", speaker: "Alice"),
            segment(1, "Yo.", speaker: "Bob"),
            segment(2, "   ", speaker: "Alice")
        ]
        #expect(plainText(segments, useSpeakerColor: true) == "Hi. Yo.")
    }
}
