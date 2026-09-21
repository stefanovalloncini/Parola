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
    /// Wall-clock seconds the engine run took, measured from the first engine call after any model
    /// download to the finished transcript. Nil for anything that did not run through a file
    /// transcription: imported subtitles, captions, dictation, live takes.
    public var transcriptionSeconds: Double?
    public var summary: Summary?
    public var chatHistory: [ChatMessage]?

    /// Set only when the caller left the language unset and the engine has something to say about
    /// it. `.assumed` means the language above is a guess the user should be given a chance to
    /// correct; nil means the run answered no such question.
    public var languageDetection: LanguageDetection?

    /// The transcript rendered in another language, or nil when it has never been translated.
    public var translation: TranscriptTranslation?

    public init(
        schemaVersion: Int = Transcript.currentSchemaVersion,
        segments: [TranscriptSegment],
        language: String,
        modelName: String,
        sourceURL: URL? = nil,
        durationSeconds: Double? = nil,
        transcriptionSeconds: Double? = nil,
        summary: Summary? = nil,
        chatHistory: [ChatMessage]? = nil,
        languageDetection: LanguageDetection? = nil,
        translation: TranscriptTranslation? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.segments = segments
        self.language = language
        self.modelName = modelName
        self.sourceURL = sourceURL
        self.durationSeconds = durationSeconds
        self.transcriptionSeconds = transcriptionSeconds
        self.summary = summary
        self.chatHistory = chatHistory
        self.languageDetection = languageDetection
        self.translation = translation
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        segments = try c.decode([TranscriptSegment].self, forKey: .segments)
        language = try c.decode(String.self, forKey: .language)
        modelName = try c.decode(String.self, forKey: .modelName)
        sourceURL = try c.decodeIfPresent(URL.self, forKey: .sourceURL)
        durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds)
        transcriptionSeconds = try c.decodeIfPresent(Double.self, forKey: .transcriptionSeconds)
        summary = try c.decodeIfPresent(Summary.self, forKey: .summary)
        chatHistory = try c.decodeIfPresent([ChatMessage].self, forKey: .chatHistory)
        languageDetection = try c.decodeIfPresent(LanguageDetection.self, forKey: .languageDetection)
        translation = try c.decodeIfPresent(TranscriptTranslation.self, forKey: .translation)
    }

    public var text: String {
        segments
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Words of spoken text, counted the way the inspector and the library statistics count them.
    public var wordCount: Int {
        segments.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
    }

    /// What the LLM features send. Diarized transcripts keep their speaker labels — prompts ask
    /// who said what, and `text` alone flattens that away. Falls back to `text` without speakers.
    public var promptText: String {
        guard segments.contains(where: { $0.speaker?.isEmpty == false }) else { return text }
        var lines: [String] = []
        var lastSpeaker: String?
        for segment in segments {
            let body = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            let speaker = segment.speaker?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let speaker, !speaker.isEmpty, speaker != lastSpeaker {
                lines.append("\(speaker): \(body)")
                lastSpeaker = speaker
            } else {
                lines.append(body)
            }
        }
        return lines.joined(separator: "\n")
    }
}
