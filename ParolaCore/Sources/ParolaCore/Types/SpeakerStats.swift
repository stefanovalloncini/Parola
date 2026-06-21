import Foundation

public struct SpeakerStats: Equatable, Sendable, Identifiable {
    public var id: String { speaker }
    public let speaker: String
    public let wordCount: Int
    public let characterCount: Int
    public let durationSeconds: Double
    public let share: Double

    public init(speaker: String, wordCount: Int, characterCount: Int, durationSeconds: Double, share: Double) {
        self.speaker = speaker
        self.wordCount = wordCount
        self.characterCount = characterCount
        self.durationSeconds = durationSeconds
        self.share = share
    }

    public static func compute(for transcript: Transcript) -> [SpeakerStats] {
        var order: [String] = []
        var aggregates: [String: (words: Int, characters: Int, duration: Double)] = [:]
        for segment in transcript.segments {
            guard let speaker = segment.speaker, !speaker.isEmpty else { continue }
            if aggregates[speaker] == nil {
                order.append(speaker)
                aggregates[speaker] = (0, 0, 0)
            }
            let words = segment.text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
            let characters = segment.text.count
            aggregates[speaker]?.words += words
            aggregates[speaker]?.characters += characters
            aggregates[speaker]?.duration += segment.duration
        }
        let total = aggregates.values.reduce(0.0) { $0 + $1.duration }
        return order.map { speaker in
            let agg = aggregates[speaker] ?? (0, 0, 0)
            let share = total > 0 ? agg.duration / total : 0
            return SpeakerStats(
                speaker: speaker,
                wordCount: agg.words,
                characterCount: agg.characters,
                durationSeconds: agg.duration,
                share: share
            )
        }
    }
}
