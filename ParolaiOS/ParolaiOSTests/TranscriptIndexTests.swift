import Testing
import Foundation
@testable import Parola
import ParolaCore

@Suite("TranscriptIndex")
struct TranscriptIndexTests {
    @Test(
        "segmentID lookups",
        arguments: [
            (0.0, 0),
            (0.5, 0),
            (1.2, 1),
            (0.95, nil),
        ] as [(Double, TranscriptSegment.ID?)]
    )
    func segmentLookup(at time: Double, expected: TranscriptSegment.ID?) {
        let index = TranscriptIndex(transcript: Fixtures.makeTranscript())
        #expect(index.segmentID(at: time) == expected)
    }

    @Test(
        "word lookups",
        arguments: [
            (0.2, "Hello"),
            (0.6, "world"),
            (1.3, "Goodbye"),
            (0.45, nil),
        ] as [(Double, String?)]
    )
    func wordLookup(at time: Double, expected: String?) {
        let index = TranscriptIndex(transcript: Fixtures.makeTranscript())
        #expect(index.word(at: time)?.word == expected)
    }

    @Test("segment boundaries are inclusive on both ends")
    func segmentBoundariesInclusive() {
        let index = TranscriptIndex(transcript: Fixtures.makeTranscript())
        #expect(index.segmentID(at: 0.0) == 0)
        #expect(index.segmentID(at: 0.9) == 0)
        #expect(index.segmentID(at: 1.0) == 1)
        #expect(index.segmentID(at: 1.6) == 1)
    }

    @Test("hasWordTimestamps is false when no segments carry words")
    func hasWordTimestampsFalse() {
        let transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "x")],
            language: "en",
            modelName: "test"
        )
        let index = TranscriptIndex(transcript: transcript)
        #expect(index.hasWordTimestamps == false)
    }
}
