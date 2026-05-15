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
}
