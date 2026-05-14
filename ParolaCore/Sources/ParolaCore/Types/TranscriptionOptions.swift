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

    public init(
        model: String? = nil,
        language: String? = nil,
        task: TranscriptionTask = .transcribe,
        wordTimestamps: Bool = false,
        verbose: Bool = false,
        initialPrompt: String? = nil
    ) {
        self.model = model
        self.language = language
        self.task = task
        self.wordTimestamps = wordTimestamps
        self.verbose = verbose
        self.initialPrompt = initialPrompt
    }

    public static let `default` = TranscriptionOptions()
}
