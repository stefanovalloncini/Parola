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
        compute(segments: segments, wordCounts: segments.map { countWords($0.text) }, binSeconds: binSeconds)
    }

    /// `wordCounts` holds one count per segment, as `TranscriptTextStats.segmentWordCounts` does.
    public static func compute(
        segments: [TranscriptSegment],
        wordCounts: [Int],
        binSeconds: Double = 30
    ) -> [SpeechRateBin] {
        guard binSeconds > 0, !segments.isEmpty else { return [] }
        let total = segments.map(\.end).max() ?? 0
        guard total > 0 else { return [] }
        let rawBinCount = ceil(total / binSeconds)
        let binCount = rawBinCount >= Double(maxBins) ? maxBins : Int(rawBinCount)
        guard binCount > 0 else { return [] }
        var counts = Array(repeating: 0.0, count: binCount)

        for (seg, words) in zip(segments, wordCounts) {
            guard words > 0, seg.end > seg.start else { continue }
            let duration = seg.end - seg.start
            let wordsPerSecond = Double(words) / duration
            let firstBin = binIndex(seg.start / binSeconds, binCount: binCount)
            let lastBin = max(firstBin, binIndex((seg.end - 0.000_001) / binSeconds, binCount: binCount))
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

    // Ceiling so a malformed import's huge-finite segment end can't blow up the bin array (~35 days at 30s bins).
    private static let maxBins = 100_000

    private static func binIndex(_ raw: Double, binCount: Int) -> Int {
        Int(min(Double(binCount - 1), max(0, raw)))
    }

    private static func countWords(_ text: String) -> Int {
        text.split { !$0.isLetter && !$0.isNumber }.count
    }
}
