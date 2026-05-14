import Testing
import Foundation
@testable import Parola
import ParolaCore

@Suite("TranscriptIndex")
struct TranscriptIndexTests {
    private func makeTranscript() -> Transcript {
        let words0 = [
            WordTiming(id: "0_0", word: "Hello", start: 0.0, end: 0.4, probability: 1),
            WordTiming(id: "0_1", word: "world", start: 0.5, end: 0.9, probability: 1),
        ]
        let words1 = [
            WordTiming(id: "1_0", word: "Goodbye", start: 1.0, end: 1.6, probability: 1),
        ]
        return Transcript(
            segments: [
                TranscriptSegment(id: 0, start: 0.0, end: 0.9, text: "Hello world", words: words0),
                TranscriptSegment(id: 1, start: 1.0, end: 1.6, text: "Goodbye", words: words1),
            ],
            language: "en",
            modelName: "test"
        )
    }

    @Test("segmentID returns the segment covering the given time")
    func segmentIDAtTime() {
        let index = TranscriptIndex(transcript: makeTranscript())
        #expect(index.segmentID(at: 0.0) == 0)
        #expect(index.segmentID(at: 0.5) == 0)
        #expect(index.segmentID(at: 1.2) == 1)
    }

    @Test("segmentID is nil between segments")
    func segmentIDBetweenSegments() {
        let index = TranscriptIndex(transcript: makeTranscript())
        #expect(index.segmentID(at: 0.95) == nil)
    }

    @Test("word lookup returns the active word")
    func wordAtTime() {
        let index = TranscriptIndex(transcript: makeTranscript())
        #expect(index.word(at: 0.2)?.word == "Hello")
        #expect(index.word(at: 0.6)?.word == "world")
        #expect(index.word(at: 1.3)?.word == "Goodbye")
    }

    @Test("word lookup is nil in the gap between words")
    func wordInGap() {
        let index = TranscriptIndex(transcript: makeTranscript())
        #expect(index.word(at: 0.45) == nil)
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
