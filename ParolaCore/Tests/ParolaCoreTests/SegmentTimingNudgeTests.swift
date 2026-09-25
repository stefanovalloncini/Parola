import Foundation
import Testing
@testable import ParolaCore

@Suite("Segment timing nudge")
struct SegmentTimingNudgeTests {
    private func makeSegment(_ id: Int, start: Double, end: Double) -> TranscriptSegment {
        TranscriptSegment(id: id, start: start, end: end, text: "s\(id)")
    }

    @Test("nudge start moves only the start by frame delta")
    func nudgeStart() {
        let segments = [makeSegment(1, start: 1, end: 2), makeSegment(2, start: 2, end: 3)]
        let result = SegmentTimingNudge.nudgeStart(segments: segments, id: 1, frameDelta: 1, fps: 25)
        let frame = Double(1) / 25
        #expect(result[0].start == 1 + frame)
        #expect(result[0].end == 2)
    }

    @Test("nudge end moves only the end by frame delta")
    func nudgeEnd() {
        let segments = [makeSegment(1, start: 1, end: 2)]
        let result = SegmentTimingNudge.nudgeEnd(segments: segments, id: 1, frameDelta: -1, fps: 24)
        let frame = Double(1) / 24
        #expect(result[0].end == 2 - frame)
    }

    @Test("nudge start cannot push past the segment's end")
    func nudgeStartClampedByEnd() {
        let segments = [makeSegment(1, start: 1.0, end: 1.04)]
        let result = SegmentTimingNudge.nudgeStart(segments: segments, id: 1, frameDelta: 5, fps: 25)
        let minGap = SegmentTimingNudge.minSegmentDuration
        let expectedStart = 1.04 - minGap
        #expect(abs(result[0].start - expectedStart) < 1e-9)
    }

    @Test("nudge end cannot fall below the segment's start")
    func nudgeEndClampedByStart() {
        let segments = [makeSegment(1, start: 1.0, end: 1.04)]
        let result = SegmentTimingNudge.nudgeEnd(segments: segments, id: 1, frameDelta: -10, fps: 25)
        let minGap = SegmentTimingNudge.minSegmentDuration
        let expectedEnd = 1.0 + minGap
        #expect(abs(result[0].end - expectedEnd) < 1e-9)
    }

    @Test("nudge end cannot push into the next segment's start")
    func nudgeEndClampedByNeighbor() {
        let segments = [
            makeSegment(1, start: 0, end: 1),
            makeSegment(2, start: 1.04, end: 2),
        ]
        let result = SegmentTimingNudge.nudgeEnd(segments: segments, id: 1, frameDelta: 5, fps: 25)
        #expect(result[0].end == 1.04)
    }

    @Test("nudge start cannot push before the previous segment's end")
    func nudgeStartClampedByNeighbor() {
        let segments = [
            makeSegment(1, start: 0, end: 0.96),
            makeSegment(2, start: 1, end: 2),
        ]
        let result = SegmentTimingNudge.nudgeStart(segments: segments, id: 2, frameDelta: -5, fps: 25)
        #expect(result[1].start == 0.96)
    }

    @Test("the first segment's start stops at the recording's start")
    func nudgeStartStopsAtZero() {
        let segments = [makeSegment(1, start: 0, end: 1)]
        #expect(SegmentTimingNudge.nudgedStart(segments: segments, id: 1, frameDelta: -1, fps: 25) == 0)
        #expect(SegmentTimingNudge.nudgeStart(segments: segments, id: 1, frameDelta: -1, fps: 25) == segments)
    }

    @Test("a bound at its limit reports where it already is, so the control can tell it won't move")
    func nudgedAtTheLimitStaysPut() {
        let segments = [makeSegment(1, start: 0, end: 1), makeSegment(2, start: 1, end: 2)]
        #expect(SegmentTimingNudge.nudgedEnd(segments: segments, id: 1, frameDelta: 1, fps: 30) == 1)
        #expect(SegmentTimingNudge.nudgedStart(segments: segments, id: 2, frameDelta: -1, fps: 30) == 1)
        #expect(SegmentTimingNudge.nudgedEnd(segments: segments, id: 2, frameDelta: 1, fps: 30) == 2 + 1.0 / 30)
        #expect(SegmentTimingNudge.nudgedStart(segments: segments, id: 1, frameDelta: 1, fps: 0) == nil)
        #expect(SegmentTimingNudge.nudgedStart(segments: segments, id: 99, frameDelta: 1, fps: 30) == nil)
    }

    @Test("overlapping neighbours never make a nudge jump the other way")
    func overlapStaysPut() {
        let segments = [makeSegment(1, start: 0, end: 1.5), makeSegment(2, start: 1, end: 2)]
        #expect(SegmentTimingNudge.nudgedStart(segments: segments, id: 2, frameDelta: -1, fps: 25) == 1)
        #expect(SegmentTimingNudge.nudgedEnd(segments: segments, id: 1, frameDelta: 1, fps: 25) == 1.5)
    }

    @Test("nudging an unknown id leaves segments unchanged")
    func unknownId() {
        let segments = [makeSegment(1, start: 0, end: 1)]
        let result = SegmentTimingNudge.nudgeStart(segments: segments, id: 99, frameDelta: 1, fps: 25)
        #expect(result == segments)
    }

    @Test("invalid fps is ignored and returns segments unchanged")
    func invalidFps() {
        let segments = [makeSegment(1, start: 0, end: 1)]
        let result = SegmentTimingNudge.nudgeStart(segments: segments, id: 1, frameDelta: 1, fps: 0)
        #expect(result == segments)
    }
}
