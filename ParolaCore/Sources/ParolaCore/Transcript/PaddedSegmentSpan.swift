import Foundation

/// Whisper stretches a short phrase across the whole silent window it decoded, so three words can
/// claim twenty-six seconds of a recording. Word timings say where those words actually are; a run
/// without them gets a plausible spoken length instead, so the rest of the window reads as the
/// silence it is.
enum PaddedSegmentSpan {
    static let longestUnpaddedSpan = 10.0
    static let paddedTextWordLimit = 3
    static let assumedSpokenSpan = 3.0

    static func clamped(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        segments.map(clamped)
    }

    static func clamped(_ segment: TranscriptSegment) -> TranscriptSegment {
        guard segment.end - segment.start > longestUnpaddedSpan,
              wordCount(segment.text) <= paddedTextWordLimit else {
            return segment
        }
        var out = segment
        if let words = segment.words, let first = words.first, let last = words.last,
           last.end > first.start {
            out.start = min(max(segment.start, first.start), segment.end)
            out.end = max(out.start, min(segment.end, last.end))
        } else {
            out.end = segment.start + assumedSpokenSpan
        }
        return out
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}
