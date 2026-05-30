import Foundation
import Testing
@testable import ParolaCore

@Suite("Parakeet word merging")
struct ParakeetWordMergeTests {
    @Test("sub-word tokens merge into whole words with spanning timings and averaged confidence")
    func mergesSubWordTokens() {
        let words = ParakeetTranscriber.mergeWords([
            .init(token: " transcri", start: 0.0, end: 0.2, confidence: 0.9),
            .init(token: "ption", start: 0.2, end: 0.4, confidence: 0.8),
            .init(token: " works", start: 0.5, end: 0.7, confidence: 1.0),
        ], segmentID: 3)

        #expect(words.map(\.word) == ["transcription", "works"])
        #expect(words.map(\.id) == ["3-0", "3-1"])
        #expect(words[0].start == 0.0)
        #expect(words[0].end == 0.4)
        #expect(words[1].start == 0.5)
        #expect(words[1].end == 0.7)
        #expect(abs(words[0].probability - 0.85) < 1e-9)
    }

    @Test("whitespace-only pieces do not produce empty words")
    func skipsWhitespaceOnlyPieces() {
        let words = ParakeetTranscriber.mergeWords([
            .init(token: "\n", start: 0.0, end: 0.0, confidence: 1.0),
            .init(token: " hello", start: 0.1, end: 0.3, confidence: 0.9),
        ], segmentID: 0)

        #expect(words.map(\.word) == ["hello"])
    }
}
