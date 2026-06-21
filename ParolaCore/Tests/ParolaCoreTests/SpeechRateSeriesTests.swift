import Foundation
import Testing
@testable import ParolaCore

@Suite("Speech rate series")
struct SpeechRateSeriesTests {
    @Test("empty segments yields empty series")
    func empty() {
        #expect(SpeechRateSeries.compute(segments: []).isEmpty)
    }

    @Test("uniform speech distributes evenly across bins")
    func uniform() {
        let segments = [
            TranscriptSegment(id: 1, start: 0, end: 60, text: String(repeating: "word ", count: 120))
        ]
        let series = SpeechRateSeries.compute(segments: segments, binSeconds: 30)
        #expect(series.count == 2)
        #expect(abs(series[0].wordsPerMinute - 120) < 0.5)
        #expect(abs(series[1].wordsPerMinute - 120) < 0.5)
    }

    @Test("higher density in second bin")
    func denserSecondBin() {
        let segments = [
            TranscriptSegment(id: 1, start: 0, end: 30, text: String(repeating: "a ", count: 30)),
            TranscriptSegment(id: 2, start: 30, end: 60, text: String(repeating: "b ", count: 90)),
        ]
        let series = SpeechRateSeries.compute(segments: segments, binSeconds: 30)
        #expect(series.count == 2)
        #expect(series[1].wordsPerMinute > series[0].wordsPerMinute)
    }

    @Test("bin starts are monotonically increasing")
    func binStartsMonotonic() {
        let segments = [
            TranscriptSegment(id: 1, start: 0, end: 90, text: "alpha bravo charlie delta echo")
        ]
        let series = SpeechRateSeries.compute(segments: segments, binSeconds: 30)
        for i in 1..<series.count {
            #expect(series[i].startSeconds > series[i - 1].startSeconds)
        }
    }

    @Test("sub-microsecond segment on a bin boundary does not trap")
    func degenerateSegmentOnBoundary() {
        let segments = [
            TranscriptSegment(id: 1, start: 0, end: 30, text: String(repeating: "a ", count: 30)),
            TranscriptSegment(id: 2, start: 30, end: 30.000_000_5, text: "boundary"),
        ]
        let series = SpeechRateSeries.compute(segments: segments, binSeconds: 30)
        #expect(series.count == 2)
        #expect(series[1].wordsPerMinute > 0)
    }

    @Test("out-of-order segments do not trap")
    func outOfOrderSegments() {
        let segments = [
            TranscriptSegment(id: 1, start: 60, end: 65, text: "hello world"),
            TranscriptSegment(id: 2, start: 0, end: 5, text: "foo bar"),
        ]
        let series = SpeechRateSeries.compute(segments: segments, binSeconds: 30)
        #expect(!series.isEmpty)
    }

    @Test("out-of-order segments span the full transcript")
    func outOfOrderSpansFullTranscript() throws {
        let segments = [
            TranscriptSegment(id: 1, start: 60, end: 90, text: String(repeating: "late ", count: 30)),
            TranscriptSegment(id: 2, start: 0, end: 30, text: String(repeating: "early ", count: 30)),
        ]
        let series = SpeechRateSeries.compute(segments: segments, binSeconds: 30)
        try #require(series.count == 3)
        #expect(abs(series[2].wordsPerMinute - 60) < 0.5)
    }

    @Test("negative start does not trap")
    func negativeStart() {
        let segments = [
            TranscriptSegment(id: 1, start: -40, end: 10, text: "alpha bravo charlie"),
        ]
        let series = SpeechRateSeries.compute(segments: segments, binSeconds: 30)
        #expect(!series.isEmpty)
    }

    @Test("a huge-finite end does not trap or allocate unboundedly")
    func hugeFiniteEndDoesNotTrap() {
        let segments = [
            TranscriptSegment(id: 1, start: 0, end: 1e21, text: "alpha bravo charlie"),
        ]
        let series = SpeechRateSeries.compute(segments: segments, binSeconds: 30)
        #expect(!series.isEmpty)
        #expect(series.count <= 100_000)
    }

    @Test("a malformed huge-finite segment among normal ones does not trap")
    func hugeFiniteSegmentAmongNormalDoesNotTrap() {
        let segments = [
            TranscriptSegment(id: 1, start: 0, end: 30, text: String(repeating: "word ", count: 60)),
            TranscriptSegment(id: 2, start: 1e20, end: 1e21, text: "garbage cue from a malformed import"),
        ]
        let series = SpeechRateSeries.compute(segments: segments, binSeconds: 30)
        #expect(!series.isEmpty)
        #expect(series.count <= 100_000)
        #expect(series[0].wordsPerMinute > 0)
    }
}
