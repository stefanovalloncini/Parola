import Foundation

public struct SpeechRateBin: Sendable, Equatable {
    public let startSeconds: Double
    public let wordsPerMinute: Double

    public init(startSeconds: Double, wordsPerMinute: Double) {
        self.startSeconds = startSeconds
        self.wordsPerMinute = wordsPerMinute
    }
}

public enum SpeechRateSeries {
    /// Buckets words across `binSeconds`-wide windows and returns words-per-minute per bin.
    /// Words are counted from each segment's text, distributed proportionally across the segment's
    /// time span. Returns an empty array if there are no segments.
    public static func compute(
        segments: [TranscriptSegment],
        binSeconds: Double = 30
    ) -> [SpeechRateBin] {
        guard binSeconds > 0, !segments.isEmpty else { return [] }
        let total = segments.last?.end ?? 0
        guard total > 0 else { return [] }
        let binCount = Int(ceil(total / binSeconds))
        guard binCount > 0 else { return [] }
        var counts = Array(repeating: 0.0, count: binCount)

        for seg in segments {
            let words = countWords(seg.text)
            guard words > 0, seg.end > seg.start else { continue }
            let duration = seg.end - seg.start
            let wordsPerSecond = Double(words) / duration
            let firstBin = Int(seg.start / binSeconds)
            let lastBin = max(firstBin, min(binCount - 1, Int((seg.end - 0.000_001) / binSeconds)))
            for bin in firstBin...lastBin {
                let binStart = Double(bin) * binSeconds
                let binEnd = binStart + binSeconds
                let overlap = max(0, min(seg.end, binEnd) - max(seg.start, binStart))
                counts[bin] += overlap * wordsPerSecond
            }
        }

        return counts.enumerated().map { idx, words in
            SpeechRateBin(startSeconds: Double(idx) * binSeconds, wordsPerMinute: (words / binSeconds) * 60)
        }
    }

    private static func countWords(_ text: String) -> Int {
        text.split { !$0.isLetter && !$0.isNumber }.count
    }
}
