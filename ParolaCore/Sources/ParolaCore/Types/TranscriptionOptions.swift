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

    public init(
        model: String? = nil,
        language: String? = nil,
        task: TranscriptionTask = .transcribe,
        wordTimestamps: Bool = false,
        verbose: Bool = false
    ) {
        self.model = model
        self.language = language
        self.task = task
        self.wordTimestamps = wordTimestamps
        self.verbose = verbose
    }

    public static let `default` = TranscriptionOptions()
}
