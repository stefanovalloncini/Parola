import Foundation
import Testing
@testable import ParolaCore

@Suite("Padded segment spans")
struct PaddedSegmentSpanTests {
    private func segment(
        start: Double, end: Double, text: String, words: [WordTiming]? = nil
    ) -> TranscriptSegment {
        TranscriptSegment(id: 0, start: start, end: end, text: text, words: words)
    }

    private func word(_ text: String, _ start: Double, _ end: Double) -> WordTiming {
        WordTiming(id: "\(start)", word: text, start: start, end: end, probability: 1)
    }

    @Test("a three-word line over a long window is cut to a spoken length")
    func padsAreCutWithoutWordTimings() {
        let clamped = PaddedSegmentSpan.clamped(segment(start: 0, end: 21, text: "Grazie a tutti."))
        #expect(clamped.start == 0)
        #expect(clamped.end == 3)
    }

    @Test("word timings win over the assumed length")
    func wordTimingsSetTheSpan() {
        let clamped = PaddedSegmentSpan.clamped(segment(
            start: 638.6, end: 650.02, text: "Grazie.",
            words: [word("Grazie.", 641.2, 642.05)]
        ))
        #expect(abs(clamped.start - 641.2) < 0.001)
        #expect(abs(clamped.end - 642.05) < 0.001)
    }

    @Test("word timings outside the segment are pulled back inside it")
    func wordTimingsStayInsideTheSegment() {
        let clamped = PaddedSegmentSpan.clamped(segment(
            start: 10, end: 40, text: "ok",
            words: [word("ok", 5, 60)]
        ))
        #expect(clamped.start == 10)
        #expect(clamped.end == 40)
    }

    @Test("degenerate word timings fall back to the assumed length")
    func degenerateWordTimingsFallBack() {
        let clamped = PaddedSegmentSpan.clamped(segment(
            start: 100, end: 130, text: "Ecco",
            words: [word("Ecco", 100, 100)]
        ))
        #expect(clamped.end == 103)
    }

    @Test("ordinary segments are left alone")
    func ordinarySegmentsAreUntouched() {
        let sentence = segment(start: 0, end: 22, text: "una frase lunga che dura parecchio e non è un riempitivo")
        #expect(PaddedSegmentSpan.clamped(sentence).end == 22)

        let short = segment(start: 0, end: 4, text: "Grazie a tutti.")
        #expect(PaddedSegmentSpan.clamped(short).end == 4)
    }

    @Test("clamping never reorders or drops a segment")
    func clampingKeepsEveryLine() {
        let input = [
            segment(start: 0, end: 21, text: "Grazie a tutti."),
            segment(start: 21, end: 25, text: "parliamo del grafico"),
            segment(start: 57.8, end: 80.3, text: "Grazie a tutti."),
        ]
        let clamped = PaddedSegmentSpan.clamped(input)
        #expect(clamped.count == 3)
        #expect(clamped.map(\.text) == input.map(\.text))
        #expect(clamped[0].end == 3)
        #expect(clamped[1].end == 25)
        #expect(clamped[2].end == 60.8)
    }
}
