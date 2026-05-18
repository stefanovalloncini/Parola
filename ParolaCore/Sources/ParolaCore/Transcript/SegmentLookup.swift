import Foundation

public extension Array where Element == TranscriptSegment {
    /// Binary-search for the segment whose `[start, end]` range covers `time`.
    /// Assumes segments are sorted by `start` and don't overlap.
    func binarySearchSegment(coveringTime time: Double) -> TranscriptSegment? {
        var lo = 0
        var hi = count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let segment = self[mid]
            if time < segment.start {
                hi = mid - 1
            } else if time > segment.end {
                lo = mid + 1
            } else {
                return segment
            }
        }
        return nil
    }
}
