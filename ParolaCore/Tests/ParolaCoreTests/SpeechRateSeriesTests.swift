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
}
