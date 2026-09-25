import Foundation

public enum SegmentTimingNudge {
    public static let minSegmentDuration: Double = 0.04

    public static func nudgeStart(
        segments: [TranscriptSegment],
        id: Int,
        frameDelta: Int,
        fps: Double
    ) -> [TranscriptSegment] {
        guard let index = segments.firstIndex(where: { $0.id == id }),
              let start = nudgedStart(segments: segments, at: index, frameDelta: frameDelta, fps: fps) else {
            return segments
        }
        var out = segments
        out[index].start = start
        return out
    }

    public static func nudgeEnd(
        segments: [TranscriptSegment],
        id: Int,
        frameDelta: Int,
        fps: Double
    ) -> [TranscriptSegment] {
        guard let index = segments.firstIndex(where: { $0.id == id }),
              let end = nudgedEnd(segments: segments, at: index, frameDelta: frameDelta, fps: fps) else {
            return segments
        }
        var out = segments
        out[index].end = end
        return out
    }

    /// Where a nudge would put the segment's start: never before the previous segment's end or the
    /// recording's start, never closer to its own end than `minSegmentDuration`. The current start
    /// when it can't move that way; nil for an unknown id or a frame rate that isn't positive.
    public static func nudgedStart(segments: [TranscriptSegment], id: Int, frameDelta: Int, fps: Double) -> Double? {
        guard let index = segments.firstIndex(where: { $0.id == id }) else { return nil }
        return nudgedStart(segments: segments, at: index, frameDelta: frameDelta, fps: fps)
    }

    /// Where a nudge would put the segment's end: never past the next segment's start, never closer
    /// to its own start than `minSegmentDuration`. The current end when it can't move that way; nil
    /// for an unknown id or a frame rate that isn't positive.
    public static func nudgedEnd(segments: [TranscriptSegment], id: Int, frameDelta: Int, fps: Double) -> Double? {
        guard let index = segments.firstIndex(where: { $0.id == id }) else { return nil }
        return nudgedEnd(segments: segments, at: index, frameDelta: frameDelta, fps: fps)
    }

    private static func nudgedStart(segments: [TranscriptSegment], at index: Int, frameDelta: Int, fps: Double) -> Double? {
        let segment = segments[index]
        let lower = index > 0 ? segments[index - 1].end : 0
        return nudged(segment.start, by: frameDelta, fps: fps, lower: lower, upper: segment.end - minSegmentDuration)
    }

    private static func nudgedEnd(segments: [TranscriptSegment], at index: Int, frameDelta: Int, fps: Double) -> Double? {
        let segment = segments[index]
        let upper = index < segments.count - 1 ? segments[index + 1].start : .infinity
        return nudged(segment.end, by: frameDelta, fps: fps, lower: segment.start + minSegmentDuration, upper: upper)
    }

    private static func nudged(_ value: Double, by frameDelta: Int, fps: Double, lower: Double, upper: Double) -> Double? {
        guard fps > 0 else { return nil }
        let clamped = min(max(value + Double(frameDelta) / fps, lower), upper)
        // A value already past its limit (overlapping neighbours, a sliver of a segment) stays put rather than jump the other way.
        return frameDelta < 0 ? min(clamped, value) : max(clamped, value)
    }
}
