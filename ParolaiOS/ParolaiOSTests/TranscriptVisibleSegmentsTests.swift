import Foundation
import Testing
@testable import Parola
import ParolaCore

@MainActor
@Suite("Transcript detail visible segments")
struct TranscriptVisibleSegmentsTests {
    private func segment(_ id: Int, _ text: String, speaker: String? = nil) -> TranscriptSegment {
        TranscriptSegment(id: id, start: Double(id), end: Double(id) + 1, text: text, speaker: speaker)
    }

    @Test("drops whitespace-only, newline-only, and empty segments")
    func dropsBlankSegments() {
        let segments = [
            segment(0, "Ciao."),
            segment(1, "   "),
            segment(2, "\n"),
            segment(3, ""),
            segment(4, "Come va?"),
        ]
        let visible = TranscriptDetailView.visibleSegments(segments, speaker: nil)
        #expect(visible.map(\.id) == [0, 4])
    }

    @Test("keeps non-empty segments in original order")
    func keepsOrder() {
        let segments = [segment(0, "a"), segment(1, "b"), segment(2, "c")]
        let visible = TranscriptDetailView.visibleSegments(segments, speaker: nil)
        #expect(visible.map(\.text) == ["a", "b", "c"])
    }

    @Test("speaker filter keeps only the selected speaker")
    func filtersBySpeaker() {
        let segments = [
            segment(0, "one", speaker: "Speaker 1"),
            segment(1, "two", speaker: "Speaker 2"),
            segment(2, "three", speaker: "Speaker 1"),
        ]
        let visible = TranscriptDetailView.visibleSegments(segments, speaker: "Speaker 1")
        #expect(visible.map(\.id) == [0, 2])
    }

    @Test("speaker filter still drops that speaker's blank segments")
    func filterDropsBlankForSpeaker() {
        let segments = [
            segment(0, "real", speaker: "Speaker 1"),
            segment(1, "   ", speaker: "Speaker 1"),
            segment(2, "other", speaker: "Speaker 2"),
        ]
        let visible = TranscriptDetailView.visibleSegments(segments, speaker: "Speaker 1")
        #expect(visible.map(\.id) == [0])
    }

    @Test("an all-blank transcript yields no visible segments, matching Transcript.text emptiness")
    func allBlankIsEmpty() {
        let segments = [segment(0, ""), segment(1, "  "), segment(2, "\n")]
        let visible = TranscriptDetailView.visibleSegments(segments, speaker: nil)
        #expect(visible.isEmpty)
        let transcript = Transcript(segments: segments, language: "it", modelName: "test")
        #expect(transcript.text.isEmpty)
    }
}
