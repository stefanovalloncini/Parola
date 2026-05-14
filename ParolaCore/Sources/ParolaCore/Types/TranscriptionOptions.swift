import Foundation

public enum TranscriptionTask: String, Codable, Sendable, CaseIterable {
    case transcribe
    case translate
}

public struct TranscriptionOptions: Sendable {
    public var model: String?
    public var language: String?
    public var task: TranscriptionTask
    public var wordTimestamps: Bool
    public var verbose: Bool

    /// Free-form text that biases the decoder toward specific words (proper nouns, jargon).
    /// Whisper truncates internally to ~224 tokens, so keep this short.
    public var initialPrompt: String?

    /// When true, run speaker diarization after transcription and tag each segment with a speaker.
    /// Forces `wordTimestamps` on (required for speaker/word alignment).
    public var diarize: Bool

    /// Hint for the diarizer when known. Nil → auto-detect.
    public var expectedSpeakers: Int?

    public init(
        model: String? = nil,
        language: String? = nil,
        task: TranscriptionTask = .transcribe,
        wordTimestamps: Bool = false,
        verbose: Bool = false,
        initialPrompt: String? = nil,
        diarize: Bool = false,
        expectedSpeakers: Int? = nil
    ) {
        self.model = model
        self.language = language
        self.task = task
        self.wordTimestamps = wordTimestamps || diarize
        self.verbose = verbose
        self.initialPrompt = initialPrompt
        self.diarize = diarize
        self.expectedSpeakers = expectedSpeakers
    }

    public static let `default` = TranscriptionOptions()
}
