import Foundation
@testable import Parola
import ParolaCore

enum Fixtures {
    static func makeTranscript() -> Transcript {
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

    static func makeLongTranscript(segments count: Int = 3000, wordsPerSegment: Int = 20) -> Transcript {
        let vocabulary = ["alpha", "beta", "gamma", "delta", "Parola", "meeting", "budget", "review", "lunedì", "l'altro"]
        let segments = (0..<count).map { s -> TranscriptSegment in
            let start = Double(s) * 4
            let step = 3.8 / Double(wordsPerSegment)
            let words = (0..<wordsPerSegment).map { w in
                WordTiming(
                    id: "\(s)_\(w)",
                    word: vocabulary[(s * 7 + w * 3) % vocabulary.count],
                    start: start + Double(w) * step,
                    end: start + Double(w + 1) * step,
                    probability: 1
                )
            }
            return TranscriptSegment(id: s, start: start, end: start + 3.8, text: words.map(\.word).joined(separator: " "), words: words)
        }
        return Transcript(segments: segments, language: "en", modelName: "test")
    }
}
