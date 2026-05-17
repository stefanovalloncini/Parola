import Foundation

public enum SegmentConfidence {
    public enum Bucket: Sendable, Equatable {
        case low
        case medium
        case high
    }

    public static func average(for segment: TranscriptSegment) -> Double? {
        guard let words = segment.words, !words.isEmpty else { return nil }
        let total = words.reduce(0.0) { $0 + $1.probability }
        return total / Double(words.count)
    }

    public static func transcriptAverage(for transcript: Transcript) -> Double? {
        let values = transcript.segments.compactMap { average(for: $0) }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    public static func bucket(for value: Double) -> Bucket {
        if value >= 0.9 { return .high }
        if value >= 0.7 { return .medium }
        return .low
    }

    public static func lowConfidence(segments: [TranscriptSegment]) -> [TranscriptSegment] {
        segments.filter { segment in
            guard let value = average(for: segment) else { return false }
            return bucket(for: value) == .low
        }
    }
}
