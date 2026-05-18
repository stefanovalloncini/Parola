import Foundation

public struct SegmentPause: Sendable, Equatable, Hashable {
    public let afterSegmentID: Int
    public let durationSeconds: Double

    public init(afterSegmentID: Int, durationSeconds: Double) {
        self.afterSegmentID = afterSegmentID
        self.durationSeconds = durationSeconds
    }
}

public enum SegmentPauses {
    /// Returns pauses between consecutive segments that are at least `threshold` seconds long.
    public static func detect(segments: [TranscriptSegment], thresholdSeconds: Double) -> [SegmentPause] {
        guard segments.count >= 2, thresholdSeconds > 0 else { return [] }
        var out: [SegmentPause] = []
        for idx in 0..<(segments.count - 1) {
            let current = segments[idx]
            let next = segments[idx + 1]
            let gap = next.start - current.end
            if gap >= thresholdSeconds {
                out.append(SegmentPause(afterSegmentID: current.id, durationSeconds: gap))
            }
        }
        return out
    }
}
