import Foundation
import Testing
import ParolaCore
@testable import Parola

@MainActor
@Suite("SegmentsScroll visible segments")
struct SegmentsVisibilityTests {
    private func segment(_ id: Int, _ text: String, speaker: String? = nil) -> TranscriptSegment {
        TranscriptSegment(id: id, start: Double(id), end: Double(id) + 1, text: text, speaker: speaker)
    }

    @Test("keeps every segment with real text when unfiltered")
    func keepsRealSegments() {
        let segments = [segment(0, "Hello."), segment(1, "World.")]
        let visible = SegmentsScroll.visibleSegments(from: segments, speakerFilter: nil)
        #expect(visible.map(\.id) == [0, 1])
    }

    @Test("drops a whitespace-only segment so Segments mode matches Transcript mode")
    func dropsEmptySegment() {
        let segments = [segment(0, "Hello."), segment(1, "  \n\t "), segment(2, "World.")]
        let visible = SegmentsScroll.visibleSegments(from: segments, speakerFilter: nil)
        #expect(visible.map(\.id) == [0, 2])
    }

    @Test("speaker filter keeps only that speaker's real segments")
    func speakerFilterKeepsSpeaker() {
        let segments = [
            segment(0, "Hi.", speaker: "Alice"),
            segment(1, "Yo.", speaker: "Bob"),
            segment(2, "Bye.", speaker: "Alice")
        ]
        let visible = SegmentsScroll.visibleSegments(from: segments, speakerFilter: "Alice")
        #expect(visible.map(\.id) == [0, 2])
    }

    @Test("speaker filter also drops that speaker's empty segments")
    func speakerFilterDropsEmpty() {
        let segments = [
            segment(0, "Hi.", speaker: "Alice"),
            segment(1, "   ", speaker: "Alice"),
            segment(2, "Yo.", speaker: "Bob")
        ]
        let visible = SegmentsScroll.visibleSegments(from: segments, speakerFilter: "Alice")
        #expect(visible.map(\.id) == [0])
    }
}
