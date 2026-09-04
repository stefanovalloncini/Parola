import Foundation
import ParolaCore

extension DictationMode: LogSafe {
    public var logToken: String { rawValue }
}

extension DictationCoordinator.State: LogSafe {
    /// Case name only: `.failed` carries an engine message that can name a file or quote speech.
    public var logToken: String {
        switch self {
        case .idle: return "idle"
        case .listening: return "listening"
        case .transcribing: return "transcribing"
        case .failed: return "failed"
        }
    }
}
