import Foundation
import Testing
@testable import ParolaCore

@Suite("Segment confidence")
struct SegmentConfidenceTests {
    private func word(_ id: String, prob: Double) -> WordTiming {
        WordTiming(id: id, word: "w", start: 0, end: 0.1, probability: prob)
    }

    @Test("nil for a segment with no word timings")
    func noWords() {
        let seg = TranscriptSegment(id: 1, start: 0, end: 1, text: "no words")
        #expect(SegmentConfidence.average(for: seg) == nil)
    }

    @Test("average across word probabilities")
    func averageAcross() {
        let seg = TranscriptSegment(
            id: 1, start: 0, end: 1, text: "x",
            words: [word("1-0", prob: 0.6), word("1-1", prob: 0.8)]
        )
        let conf = SegmentConfidence.average(for: seg)
        #expect(conf == 0.7)
    }

    @Test(
        "bucket maps probability to low / medium / high",
        arguments: [
            (probability: 0.4, expected: SegmentConfidence.Bucket.low),
            (probability: 0.69, expected: .low),
            (probability: 0.7, expected: .medium),
            (probability: 0.85, expected: .medium),
            (probability: 0.9, expected: .high),
            (probability: 1.0, expected: .high),
        ]
    )
    func bucket(probability: Double, expected: SegmentConfidence.Bucket) {
        #expect(SegmentConfidence.bucket(for: probability) == expected)
    }

    @Test("transcript-wide average is the per-segment mean ignoring nils")
    func transcriptAverage() {
        let segments = [
            TranscriptSegment(id: 1, start: 0, end: 1, text: "x", words: [word("1-0", prob: 0.6)]),
            TranscriptSegment(id: 2, start: 1, end: 2, text: "y", words: [word("2-0", prob: 0.9)]),
            TranscriptSegment(id: 3, start: 2, end: 3, text: "z"),
        ]
        let transcript = Transcript(
            schemaVersion: 1, segments: segments, language: "en", modelName: "x"
        )
        #expect(SegmentConfidence.transcriptAverage(for: transcript) == 0.75)
    }

    @Test("transcript average is nil when no segment has words")
    func transcriptAverageNil() {
        let transcript = Transcript(
            schemaVersion: 1,
            segments: [TranscriptSegment(id: 1, start: 0, end: 1, text: "x")],
            language: "en",
            modelName: "x"
        )
        #expect(SegmentConfidence.transcriptAverage(for: transcript) == nil)
    }

    @Test("low confidence segments are the ones bucketed as low")
    func lowConfidence() {
        let segments = [
            TranscriptSegment(id: 1, start: 0, end: 1, text: "x", words: [word("1-0", prob: 0.6)]),
            TranscriptSegment(id: 2, start: 1, end: 2, text: "y", words: [word("2-0", prob: 0.95)]),
            TranscriptSegment(id: 3, start: 2, end: 3, text: "z", words: [word("3-0", prob: 0.5)]),
        ]
        let lows = SegmentConfidence.lowConfidence(segments: segments)
        #expect(lows.map(\.id) == [1, 3])
    }
}
