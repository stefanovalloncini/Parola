import Foundation

public extension Array where Element == TranscriptSegment {
    /// Binary-search for the segment whose `[start, end]` range covers `time`.
    /// Assumes segments are sorted by `start` and don't overlap.
    func binarySearchSegment(coveringTime time: Double) -> TranscriptSegment? {
        binarySearchSegmentIndex(coveringTime: time).map { self[$0] }
    }

    /// Index variant of `binarySearchSegment(coveringTime:)` for callers that cache positions.
    func binarySearchSegmentIndex(coveringTime time: Double) -> Int? {
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
                return mid
            }
        }
        return nil
    }

    /// Binary-search for the first segment whose `start` is greater than `time`. Assumes segments are sorted by `start`.
    func firstSegment(startingAfter time: Double) -> TranscriptSegment? {
        var lo = 0
        var hi = count
        while lo < hi {
            let mid = (lo + hi) / 2
            if self[mid].start > time {
                hi = mid
            } else {
                lo = mid + 1
            }
        }
        return lo < count ? self[lo] : nil
    }
}
