import Foundation
import ParolaCore

struct TranscriptIndex: Sendable {
    let segments: [TranscriptSegment]
    let words: [WordTiming]
    let hasWordTimestamps: Bool

    init(transcript: Transcript) {
        let segs = transcript.segments
        self.segments = segs
        let flat = segs.flatMap { $0.words ?? [] }
        self.words = flat
        self.hasWordTimestamps = !flat.isEmpty
    }

    func segmentID(at time: Double) -> TranscriptSegment.ID? {
        binarySearch(segments, time: time, start: \.start, end: \.end)?.id
    }

    func word(at time: Double) -> WordTiming? {
        binarySearch(words, time: time, start: \.start, end: \.end)
    }

    private func binarySearch<T>(
        _ array: [T],
        time: Double,
        start: KeyPath<T, Double>,
        end: KeyPath<T, Double>
    ) -> T? {
        var lo = 0
        var hi = array.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let item = array[mid]
            let s = item[keyPath: start]
            let e = item[keyPath: end]
            if time < s { hi = mid - 1 }
            else if time > e { lo = mid + 1 }
            else { return item }
        }
        return nil
    }
}
