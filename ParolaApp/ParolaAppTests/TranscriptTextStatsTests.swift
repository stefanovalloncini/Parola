import Foundation
import Testing
@testable import Parola

@Suite("Transcript text stats snapshot")
struct TranscriptTextStatsTests {
    @Test("counts match the inspector's formulas")
    func countsMatchFormulas() {
        let text = "Well, um this is a test. It has two sentences, you know?"
        let stats = TranscriptTextStats.compute(text: text)
        #expect(stats.charCount == text.count)
        #expect(stats.wordCount == text.split { $0.isWhitespace || $0.isNewline }.count)
        #expect(stats.sentenceCount == 2)
        #expect(stats.fillerCount > 0)
    }

    @Test("empty text yields zeroed stats")
    func emptyTextZeroes() {
        #expect(TranscriptTextStats.compute(text: "") == TranscriptTextStats())
    }
}
