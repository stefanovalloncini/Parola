import Foundation
import WhisperKit

/// How a WhisperKit segment becomes a transcript segment, for a file run and a live take alike.
enum WhisperSegmentMapping {
    static func segment(_ raw: TranscriptionSegment, id: Int) -> TranscriptSegment {
        TranscriptSegment(
            id: id,
            start: Double(raw.start),
            end: Double(raw.end),
            text: SpokenText.normalized(raw.text),
            words: raw.words?.enumerated().map { index, word in
                WordTiming(
                    id: "\(id)-\(index)",
                    word: word.word.trimmingCharacters(in: .whitespaces),
                    start: Double(word.start),
                    end: Double(word.end),
                    probability: Double(word.probability)
                )
            }
        )
    }
}
