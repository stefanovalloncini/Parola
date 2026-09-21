import Foundation
import Testing
import ParolaCore
@testable import Parola

@MainActor
@Suite("Paragraphed transcript text")
struct TranscriptParagraphTextTests {

    private func segment(
        _ id: Int,
        _ text: String,
        start: Double,
        end: Double,
        speaker: String? = nil
    ) -> TranscriptSegment {
        TranscriptSegment(id: id, start: start, end: end, text: text, speaker: speaker)
    }

    private func text(_ segments: [TranscriptSegment], labels: Bool = false) -> String {
        TranscriptParagraphs.plainText(segments: segments, includeSpeakerLabels: labels)
    }

    @Test("a speaker change puts a blank line between the paragraphs")
    func speakerChangeSeparatesParagraphs() {
        let segments = [
            segment(0, "Hi.", start: 0, end: 4, speaker: "Alice"),
            segment(1, "Yo.", start: 4, end: 8, speaker: "Bob")
        ]
        #expect(text(segments, labels: true) == "Alice\nHi.\n\nBob\nYo.")
    }

    @Test("a pause at the threshold puts a blank line between the paragraphs")
    func pauseSeparatesParagraphs() {
        let segments = [
            segment(0, "First.", start: 0, end: 4),
            segment(1, "Second.", start: 4 + TranscriptDerive.paragraphPauseSeconds, end: 12)
        ]
        #expect(text(segments) == "First.\n\nSecond.")
    }

    @Test("a pause under the threshold keeps one paragraph")
    func shortPauseKeepsOneParagraph() {
        let segments = [
            segment(0, "First.", start: 0, end: 4),
            segment(1, "Second.", start: 5.4, end: 12)
        ]
        #expect(text(segments) == "First. Second.")
    }

    @Test("without speaker labels a speaker change still breaks the paragraph")
    func unlabelledSpeakerChangeStillBreaks() {
        let segments = [
            segment(0, "Hi.", start: 0, end: 4, speaker: "Alice"),
            segment(1, "Yo.", start: 8, end: 12, speaker: "Bob")
        ]
        #expect(text(segments) == "Hi.\n\nYo.")
    }

    @Test("a whitespace-only segment leaves no stray space or blank line")
    func blankSegmentLeavesNoArtefact() {
        let segments = [
            segment(0, "First.", start: 0, end: 4),
            segment(1, "   ", start: 4, end: 5),
            segment(2, "Second.", start: 5, end: 9)
        ]
        #expect(text(segments) == "First. Second.")
    }

    @Test("no segments yield an empty string")
    func emptyInput() {
        #expect(text([]) == "")
    }

    @Test("the copied text reads the way the pane renders it")
    func matchesRenderedChunks() {
        let segments = [
            segment(0, "Hi.", start: 0, end: 4, speaker: "Alice"),
            segment(1, "Still me.", start: 8, end: 12, speaker: "Alice"),
            segment(2, "Yo.", start: 12, end: 16, speaker: "Bob")
        ]
        let rendered = ContinuousChunks.build(
            segments: segments,
            useSpeakerColor: true,
            speakerColorIndices: [:],
            primaryText: DS.Color.primaryText,
            favoriteColor: DS.Color.accent,
            favorites: [],
            translations: [:],
            translationColor: DS.Color.secondaryText
        ).map { String($0.text.characters) }

        #expect(rendered.joined(separator: "\n\n") == text(segments, labels: true))
    }
}
