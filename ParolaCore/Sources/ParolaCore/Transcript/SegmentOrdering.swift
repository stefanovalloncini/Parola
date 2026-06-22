import Foundation

extension Array where Element == TranscriptSegment {
    /// Returns the segments in start-time order with positional ids reassigned so each
    /// `id` matches its new index (word ids follow). WhisperKit's VAD chunking can emit
    /// segments out of order; `binarySearchSegment`, the exporters, and the player highlight
    /// all assume chronological order.
    func chronologicallyOrdered() -> [TranscriptSegment] {
        sorted { $0.start < $1.start }.enumerated().map { index, segment in
            var seg = segment
            seg.id = index
            if let words = seg.words {
                seg.words = words.enumerated().map { wordIndex, word in
                    var w = word
                    w.id = "\(index)-\(wordIndex)"
                    return w
                }
            }
            return seg
        }
    }
}
