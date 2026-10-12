import Foundation
import ParolaCore

struct TranscriptIndex: Sendable {
    let segments: [TranscriptSegment]
    let words: [WordTiming]
    let hasWordTimestamps: Bool

    init(transcript: Transcript) {
        let segs = transcript.segments.sorted { $0.start < $1.start }
        self.segments = segs
        self.words = segs.flatMap { $0.words ?? [] }.sorted { $0.start < $1.start }
        self.hasWordTimestamps = !words.isEmpty
    }

    func segmentID(at time: Double) -> TranscriptSegment.ID? {
        predecessor(in: segments, at: time, start: \.start, end: \.end)?.id
    }

    func word(at time: Double) -> WordTiming? {
        predecessor(in: words, at: time, start: \.start, end: \.end)
    }

    static func segmentID(at time: Double, scanning segments: [TranscriptSegment]) -> TranscriptSegment.ID? {
        var best: TranscriptSegment?
        for segment in segments where segment.start <= time {
            if let current = best, segment.start < current.start { continue }
            best = segment
        }
        guard let best, time <= best.end else { return nil }
        return best.id
    }

    private func predecessor<T>(
        in array: [T],
        at time: Double,
        start: KeyPath<T, Double>,
        end: KeyPath<T, Double>
    ) -> T? {
        var lo = 0
        var hi = array.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if array[mid][keyPath: start] <= time { lo = mid + 1 } else { hi = mid }
        }
        guard lo > 0 else { return nil }
        let item = array[lo - 1]
        return time <= item[keyPath: end] ? item : nil
    }
}
