import Foundation
import Testing
@testable import ParolaCore

@Suite("Segment pauses")
struct SegmentPausesTests {
    @Test("no pauses when below threshold")
    func belowThreshold() {
        let segments = [
            seg(id: 1, start: 0, end: 1),
            seg(id: 2, start: 1.5, end: 2),
        ]
        let pauses = SegmentPauses.detect(segments: segments, thresholdSeconds: 1)
        #expect(pauses.isEmpty)
    }

    @Test("detects pauses at or above threshold")
    func aboveThreshold() {
        let segments = [
            seg(id: 1, start: 0, end: 1),
            seg(id: 2, start: 3, end: 4),
        ]
        let pauses = SegmentPauses.detect(segments: segments, thresholdSeconds: 1.5)
        #expect(pauses.count == 1)
        #expect(pauses[0].afterSegmentID == 1)
        #expect(abs(pauses[0].durationSeconds - 2) < 0.001)
    }

    @Test("multiple pauses across a transcript")
    func multiple() {
        let segments = [
            seg(id: 1, start: 0, end: 1),
            seg(id: 2, start: 5, end: 6),
            seg(id: 3, start: 6.2, end: 7),
            seg(id: 4, start: 12, end: 13),
        ]
        let pauses = SegmentPauses.detect(segments: segments, thresholdSeconds: 2)
        #expect(pauses.map(\.afterSegmentID) == [1, 3])
    }

    @Test("empty or single segment returns empty")
    func edge() {
        #expect(SegmentPauses.detect(segments: [], thresholdSeconds: 1).isEmpty)
        #expect(SegmentPauses.detect(segments: [seg(id: 1, start: 0, end: 1)], thresholdSeconds: 1).isEmpty)
    }

    private func seg(id: Int, start: Double, end: Double) -> TranscriptSegment {
        TranscriptSegment(id: id, start: start, end: end, text: "")
    }
}
