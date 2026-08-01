import Foundation
import Testing
@testable import Parola
import ParolaCore

@Suite("Info inspector derived stats")
struct InfoInspectorDerivedTests {
    private func segment(
        id: Int,
        start: Double,
        end: Double,
        speaker: String,
        text: String,
        probability: Double
    ) -> TranscriptSegment {
        let pieces = text.split(separator: " ")
        let step = (end - start) / Double(max(1, pieces.count))
        let words = pieces.enumerated().map { index, word in
            WordTiming(
                id: "\(id)-\(index)",
                word: String(word),
                start: start + Double(index) * step,
                end: start + Double(index + 1) * step,
                probability: probability
            )
        }
        return TranscriptSegment(id: id, start: start, end: end, text: text, speaker: speaker, words: words)
    }

    private func makeTranscript() -> Transcript {
        Transcript(
            segments: [
                segment(id: 1, start: 0, end: 20, speaker: "Speaker 1", text: "Hello there this is a test.", probability: 0.95),
                segment(id: 2, start: 20, end: 40, speaker: "Speaker 2", text: "And this part came out mumbled.", probability: 0.4),
                segment(id: 3, start: 40, end: 70, speaker: "Speaker 1", text: "Back to the first speaker again.", probability: 0.9)
            ],
            language: "en",
            modelName: "test"
        )
    }

    @Test("one pass covers speakers, confidence, speech rate and text stats")
    func derivesEverythingInOnePass() {
        let transcript = makeTranscript()
        let derived = InfoInspector.derive(transcript: transcript, text: transcript.text)
        #expect(derived.speakers.map(\.speaker) == ["Speaker 1", "Speaker 2"])
        #expect(abs((derived.confidenceAverage ?? 0) - 0.75) < 0.001)
        #expect(derived.lowConfidence.map(\.id) == [2])
        #expect(derived.speechRate.count == 3)
        #expect(derived.text.wordCount == TranscriptTextStats.compute(text: transcript.text).wordCount)
    }

    @Test("a transcript without words or speakers derives empty sections")
    func derivesEmptySectionsWithoutWords() {
        let transcript = Transcript(
            segments: [TranscriptSegment(id: 1, start: 0, end: 5, text: "Plain line.")],
            language: "en",
            modelName: "test"
        )
        let derived = InfoInspector.derive(transcript: transcript, text: transcript.text)
        #expect(derived.speakers.isEmpty)
        #expect(derived.confidenceAverage == nil)
        #expect(derived.lowConfidence.isEmpty)
        #expect(derived.speechRate.count == 1)
        #expect(derived.text.wordCount == 2)
    }
}
