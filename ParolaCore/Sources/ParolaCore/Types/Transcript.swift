import Foundation

public struct WordTiming: Codable, Hashable, Sendable, Identifiable {
    /// Position-based ID: segmentID followed by the word index within the segment.
    public var id: String
    public var word: String
    public var start: Double
    public var end: Double
    public var probability: Double
    public var speaker: String?

    public init(
        id: String,
        word: String,
        start: Double,
        end: Double,
        probability: Double,
        speaker: String? = nil
    ) {
        self.id = id
        self.word = word
        self.start = start
        self.end = end
        self.probability = probability
        self.speaker = speaker
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
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var segments: [TranscriptSegment]
    public var language: String
    public var modelName: String
    public var sourceURL: URL?
    public var durationSeconds: Double?
    public var summary: Summary?
    public var chatHistory: [ChatMessage]?

    public init(
        schemaVersion: Int = Transcript.currentSchemaVersion,
        segments: [TranscriptSegment],
        language: String,
        modelName: String,
        sourceURL: URL? = nil,
        durationSeconds: Double? = nil,
        summary: Summary? = nil,
        chatHistory: [ChatMessage]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.segments = segments
        self.language = language
        self.modelName = modelName
        self.sourceURL = sourceURL
        self.durationSeconds = durationSeconds
        self.summary = summary
        self.chatHistory = chatHistory
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        segments = try c.decode([TranscriptSegment].self, forKey: .segments)
        language = try c.decode(String.self, forKey: .language)
        modelName = try c.decode(String.self, forKey: .modelName)
        sourceURL = try c.decodeIfPresent(URL.self, forKey: .sourceURL)
        durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds)
        summary = try c.decodeIfPresent(Summary.self, forKey: .summary)
        chatHistory = try c.decodeIfPresent([ChatMessage].self, forKey: .chatHistory)
    }

    public var text: String {
        segments
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
