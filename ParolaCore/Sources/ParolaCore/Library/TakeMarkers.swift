import Foundation

/// Moments a user marked during a take, in seconds on the take's own clock, which skips its pauses as its audio does.
public enum TakeMarkers {
    /// The segments the markers pick: the one whose `start..<end` holds a marker, else the first to start after it.
    /// Blank segments never show, so they are never picked. Sorted, without repeats.
    public static func favoriteSegmentIDs(markers: [TimeInterval], segments: [TranscriptSegment]) -> [Int] {
        guard !markers.isEmpty else { return [] }
        let spoken = segments.droppingBlankText()
        var picked = Set<Int>()
        for marker in markers {
            if let holding = spoken.first(where: { $0.start <= marker && marker < $0.end }) {
                picked.insert(holding.id)
            } else if let next = spoken.filter({ $0.start > marker }).min(by: { $0.start < $1.start }) {
                picked.insert(next.id)
            }
        }
        return picked.sorted()
    }
}
