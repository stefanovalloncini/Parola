import Foundation
import ParolaCore

struct TranscriptTextStats: Equatable {
    var charCount = 0
    var wordCount = 0
    var sentenceCount = 0
    var fillerCount = 0

    static func compute(text: String) -> TranscriptTextStats {
        guard !text.isEmpty else { return TranscriptTextStats() }
        return TranscriptTextStats(
            charCount: text.count,
            wordCount: text.split { $0.isWhitespace || $0.isNewline }.count,
            sentenceCount: SentenceCounter.count(text),
            fillerCount: FillerWordCounter.count(in: text)
        )
    }
}
