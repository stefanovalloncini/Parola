import Foundation
import Testing
@testable import ParolaCore

@Suite("Word timings")
struct WordTimingTests {
    private func sampleSegment() -> TranscriptSegment {
        TranscriptSegment(
            id: 0,
            start: 0,
            end: 3.0,
            text: "Hello world today",
            words: [
                WordTiming(id: "0-0", word: "Hello", start: 0.0, end: 0.5, probability: 0.99),
                WordTiming(id: "0-1", word: "world", start: 0.6, end: 1.4, probability: 0.98),
                WordTiming(id: "0-2", word: "today", start: 1.5, end: 2.8, probability: 0.97),
            ]
        )
    }

    @Test("word(at:) returns the word covering the given time")
    func wordAt() {
        let seg = sampleSegment()
        #expect(seg.word(at: 0.2)?.word == "Hello")
        #expect(seg.word(at: 1.0)?.word == "world")
        #expect(seg.word(at: 2.0)?.word == "today")
    }

    @Test("word(at:) returns nil between word intervals")
    func wordAtGap() {
        let seg = sampleSegment()
        #expect(seg.word(at: 0.55) == nil)
    }

    @Test("word(at:) returns nil when no words present")
    func wordAtNoWords() {
        let seg = TranscriptSegment(id: 0, start: 0, end: 1, text: "x")
        #expect(seg.word(at: 0.5) == nil)
    }

    @Test("transcript round-trips through Codable with words")
    func codable() throws {
        let original = Transcript(
            segments: [sampleSegment()],
            language: "en",
            modelName: "openai_whisper-tiny"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Transcript.self, from: data)
        #expect(decoded == original)
        #expect(decoded.segments.first?.words?.count == 3)
    }
}
