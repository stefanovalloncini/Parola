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
        let visible = SegmentsScroll.visibleSegments(from: segments, speakerFilter: nil, favorites: [], favoritesOnly: false)
        #expect(visible.map(\.id) == [0, 1])
    }

    @Test("drops a whitespace-only segment so Segments mode matches Transcript mode")
    func dropsEmptySegment() {
        let segments = [segment(0, "Hello."), segment(1, "  \n\t "), segment(2, "World.")]
        let visible = SegmentsScroll.visibleSegments(from: segments, speakerFilter: nil, favorites: [], favoritesOnly: false)
        #expect(visible.map(\.id) == [0, 2])
    }

    @Test("speaker filter keeps only that speaker's real segments")
    func speakerFilterKeepsSpeaker() {
        let segments = [
            segment(0, "Hi.", speaker: "Alice"),
            segment(1, "Yo.", speaker: "Bob"),
            segment(2, "Bye.", speaker: "Alice")
        ]
        let visible = SegmentsScroll.visibleSegments(from: segments, speakerFilter: "Alice", favorites: [], favoritesOnly: false)
        #expect(visible.map(\.id) == [0, 2])
    }

    @Test("speaker filter also drops that speaker's empty segments")
    func speakerFilterDropsEmpty() {
        let segments = [
            segment(0, "Hi.", speaker: "Alice"),
            segment(1, "   ", speaker: "Alice"),
            segment(2, "Yo.", speaker: "Bob")
        ]
        let visible = SegmentsScroll.visibleSegments(from: segments, speakerFilter: "Alice", favorites: [], favoritesOnly: false)
        #expect(visible.map(\.id) == [0])
    }

    // MARK: - Derived

    private func scored(_ id: Int, _ text: String, start: Double, end: Double, probability: Double) -> TranscriptSegment {
        TranscriptSegment(
            id: id,
            start: start,
            end: end,
            text: text,
            words: [WordTiming(id: "\(id)-0", word: text, start: start, end: end, probability: probability)]
        )
    }

    @Test("derive returns the pauses, the confidence buckets and the visible list in one pass")
    func deriveCoversEveryList() {
        let segments = [
            scored(0, "Hi.", start: 0, end: 1, probability: 0.95),
            scored(1, "Yo.", start: 8, end: 9, probability: 0.5)
        ]

        let derived = SegmentsScroll.derive(segments: segments, speakerFilter: nil, favorites: [], favoritesOnly: false)

        #expect(derived.pauseByPrev == [0: 7])
        #expect(derived.confidenceByID == [0: .high, 1: .low])
        #expect(derived.visible.map(\.id) == [0, 1])
    }

    @Test("derive applies the speaker filter to the visible list only")
    func deriveFiltersVisibleOnly() {
        let segments = [
            TranscriptSegment(id: 0, start: 0, end: 1, text: "Hi.", speaker: "Alice"),
            TranscriptSegment(id: 1, start: 8, end: 9, text: "Yo.", speaker: "Bob")
        ]

        let derived = SegmentsScroll.derive(segments: segments, speakerFilter: "Bob", favorites: [], favoritesOnly: false)

        #expect(derived.visible.map(\.id) == [1])
        #expect(derived.pauseByPrev == [0: 7])
    }

    @Test("derive on an empty transcript yields empty lists")
    func deriveEmpty() {
        let derived = SegmentsScroll.derive(segments: [], speakerFilter: nil, favorites: [], favoritesOnly: false)

        #expect(derived.pauseByPrev.isEmpty)
        #expect(derived.confidenceByID.isEmpty)
        #expect(derived.visible.isEmpty)
    }
}
