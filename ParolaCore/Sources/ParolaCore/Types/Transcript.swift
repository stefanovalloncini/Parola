import Foundation

public struct WordTiming: Codable, Hashable, Sendable, Identifiable {
    /// Position-based ID: segmentID followed by the word index within the segment.
    public var id: String
    public var word: String
    public var start: Double
    public var end: Double
    public var probability: Double

    public init(id: String, word: String, start: Double, end: Double, probability: Double) {
        self.id = id
        self.word = word
        self.start = start
        self.end = end
        self.probability = probability
    }

    public var duration: Double { end - start }
}

public struct TranscriptSegment: Codable, Hashable, Sendable, Identifiable {
    public var id: Int
    public var start: Double
    public var end: Double
    public var text: String
    public var speaker: String?
    public var words: [WordTiming]?

    public init(
        id: Int,
        start: Double,
        end: Double,
        text: String,
        speaker: String? = nil,
        words: [WordTiming]? = nil
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
        self.speaker = speaker
        self.words = words
    }

    public var duration: Double { end - start }

    /// Returns the word being spoken at `time`, or nil if `time` is outside any word.
    public func word(at time: Double) -> WordTiming? {
        words?.first { time >= $0.start && time <= $0.end }
    }
}

public struct Transcript: Codable, Hashable, Sendable {
    public var segments: [TranscriptSegment]
    public var language: String
    public var modelName: String
    public var sourceURL: URL?
    public var durationSeconds: Double?
    public var summary: Summary?

    public init(
        segments: [TranscriptSegment],
        language: String,
        modelName: String,
        sourceURL: URL? = nil,
        durationSeconds: Double? = nil,
        summary: Summary? = nil
    ) {
        self.segments = segments
        self.language = language
        self.modelName = modelName
        self.sourceURL = sourceURL
        self.durationSeconds = durationSeconds
        self.summary = summary
    }

    public var text: String {
        segments.map(\.text).joined(separator: " ")
    }
}
