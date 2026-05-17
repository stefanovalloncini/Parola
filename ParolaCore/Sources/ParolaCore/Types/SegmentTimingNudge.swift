import Foundation

public enum SegmentTimingNudge {
    public static let minSegmentDuration: Double = 0.04

    public static func nudgeStart(
        segments: [TranscriptSegment],
        id: Int,
        frameDelta: Int,
        fps: Double
    ) -> [TranscriptSegment] {
        guard fps > 0, let index = segments.firstIndex(where: { $0.id == id }) else {
            return segments
        }
        let proposed = segments[index].start + Double(frameDelta) / fps
        let lowerBound = index > 0 ? segments[index - 1].end : -.infinity
        let upperBound = segments[index].end - minSegmentDuration
        let clamped = min(max(proposed, lowerBound), upperBound)
        var out = segments
        out[index].start = clamped
        return out
    }

    public static func nudgeEnd(
        segments: [TranscriptSegment],
        id: Int,
        frameDelta: Int,
        fps: Double
    ) -> [TranscriptSegment] {
        guard fps > 0, let index = segments.firstIndex(where: { $0.id == id }) else {
            return segments
        }
        let proposed = segments[index].end + Double(frameDelta) / fps
        let lowerBound = segments[index].start + minSegmentDuration
        let upperBound = index < segments.count - 1 ? segments[index + 1].start : .infinity
        let clamped = min(max(proposed, lowerBound), upperBound)
        var out = segments
        out[index].end = clamped
        return out
    }
}
