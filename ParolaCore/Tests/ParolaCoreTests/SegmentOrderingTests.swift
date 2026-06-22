import Foundation
import Testing
@testable import ParolaCore

@Suite("Segment chronological ordering")
struct SegmentOrderingTests {
    @Test("sorts out-of-order segments by start time")
    func sortsByStart() {
        let segments = [
            TranscriptSegment(id: 0, start: 0, end: 5, text: "first"),
            TranscriptSegment(id: 1, start: 51.6, end: 51.7, text: "ok"),
            TranscriptSegment(id: 2, start: 45.2, end: 52.5, text: "middle"),
        ]
        let ordered = segments.chronologicallyOrdered()
        #expect(ordered.map(\.text) == ["first", "middle", "ok"])
        #expect(ordered.map(\.start) == [0, 45.2, 51.6])
    }

    @Test("reassigns positional ids matching the new order")
    func renumbersIDs() {
        let segments = [
            TranscriptSegment(id: 7, start: 10, end: 11, text: "b"),
            TranscriptSegment(id: 4, start: 2, end: 3, text: "a"),
        ]
        let ordered = segments.chronologicallyOrdered()
        #expect(ordered.map(\.id) == [0, 1])
        #expect(ordered[0].text == "a")
        #expect(ordered[1].text == "b")
    }

    @Test("reassigns word ids to follow the new segment id")
    func renumbersWordIDs() {
        let late = TranscriptSegment(
            id: 0, start: 9, end: 10, text: "two",
            words: [WordTiming(id: "0-0", word: "two", start: 9, end: 10, probability: 1)]
        )
        let early = TranscriptSegment(
            id: 1, start: 1, end: 2, text: "one",
            words: [WordTiming(id: "1-0", word: "one", start: 1, end: 2, probability: 1)]
        )
        let ordered = [late, early].chronologicallyOrdered()
        #expect(ordered[0].text == "one")
        #expect(ordered[0].words?.first?.id == "0-0")
        #expect(ordered[1].text == "two")
        #expect(ordered[1].words?.first?.id == "1-0")
    }

    @Test("preserves relative order of segments sharing a start time")
    func stableForEqualStarts() {
        let segments = [
            TranscriptSegment(id: 0, start: 3, end: 4, text: "x"),
            TranscriptSegment(id: 1, start: 3, end: 4, text: "y"),
            TranscriptSegment(id: 2, start: 1, end: 2, text: "z"),
        ]
        let ordered = segments.chronologicallyOrdered()
        #expect(ordered.map(\.text) == ["z", "x", "y"])
    }

    @Test("already-ordered input keeps its order with ids 0..<n")
    func alreadyOrdered() {
        let segments = (0..<5).map {
            TranscriptSegment(id: $0 * 10, start: Double($0), end: Double($0) + 0.5, text: "\($0)")
        }
        let ordered = segments.chronologicallyOrdered()
        #expect(ordered.map(\.start) == [0, 1, 2, 3, 4])
        #expect(ordered.map(\.id) == [0, 1, 2, 3, 4])
    }
}
