import Foundation

public enum TranscriptionTask: String, Codable, Sendable, CaseIterable {
    case transcribe
    case translate
}

public struct TranscriptionOptions: Sendable {
    public var model: String?
    public var language: String?
    public var task: TranscriptionTask

    /// Forced on when ``diarize`` is set, since speaker alignment needs word boundaries.
    public var wordTimestamps: Bool
    public var verbose: Bool

    /// Free-form text that biases the decoder toward specific words (proper nouns, jargon).
    /// Whisper truncates internally to ~111 tokens, so keep this short.
    public var initialPrompt: String?

    /// When true, run speaker diarization after transcription and tag each segment with a speaker.
    /// Forces `wordTimestamps` on (required for speaker/word alignment).
    public var diarize: Bool

    /// Hint for the diarizer when known. Nil → auto-detect.
    public var expectedSpeakers: Int?

    /// Drops the stock filler Whisper decodes out of silence — see ``HallucinationPhrases``.
    /// Set false to get the engine's output verbatim.
    public var filtersHallucinations: Bool

    public init(
        model: String? = nil,
        language: String? = nil,
        task: TranscriptionTask = .transcribe,
        wordTimestamps: Bool = false,
        verbose: Bool = false,
        initialPrompt: String? = nil,
        diarize: Bool = false,
        expectedSpeakers: Int? = nil,
        filtersHallucinations: Bool = true
    ) {
        self.model = model
        self.language = language
        self.task = task
        self.wordTimestamps = wordTimestamps || diarize
        self.verbose = verbose
        self.initialPrompt = initialPrompt
        self.diarize = diarize
        self.expectedSpeakers = expectedSpeakers
        self.filtersHallucinations = filtersHallucinations
    }

    public static let `default` = TranscriptionOptions()
}
