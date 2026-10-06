import Foundation
import WhisperKit

/// The languages Whisper was trained on, the list a model that takes any language is offered with.
public enum WhisperLanguages {
    public static let codes: Set<String> = Set(Constants.languages.values)

    /// Whisper's own English name, for a code the system has no name for ("jw", "haw").
    public static func englishName(for code: String) -> String? {
        Constants.languages
            .filter { $0.value == code }
            .map(\.key)
            .sorted()
            .first?
            .capitalized
    }
}
