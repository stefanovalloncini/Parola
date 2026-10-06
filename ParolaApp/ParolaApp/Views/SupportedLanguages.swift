import Foundation
import ParolaCore

/// The one language table shared by every picker (intake, Transcription Defaults,
/// dictation workflows) so the offered languages can't drift between surfaces.
enum SupportedLanguages {
    static let codes: [String] = [
        "en", "it", "es", "fr", "de", "pt", "nl", "ja", "zh", "ko", "ar", "ru", "hi",
    ]

    private static let fallbackNames: [String: String] = [
        "en": "English",
        "it": "Italian",
        "es": "Spanish",
        "fr": "French",
        "de": "German",
        "pt": "Portuguese",
        "nl": "Dutch",
        "ja": "Japanese",
        "zh": "Chinese",
        "ko": "Korean",
        "ar": "Arabic",
        "ru": "Russian",
        "hi": "Hindi",
    ]

    static func displayName(for code: String) -> String {
        let fallback = fallbackNames[code] ?? WhisperLanguages.englishName(for: code) ?? code
        guard let localized = Locale.current.localizedString(forLanguageCode: code) else {
            return fallback
        }
        return localized.capitalized(with: Locale.current)
    }

    static var options: [(code: String, name: String)] {
        codes.map { ($0, displayName(for: $0)) }
    }

    /// The language's name in itself, or nil when it would only repeat the localized one.
    static func endonym(for code: String) -> String? {
        let locale = Locale(identifier: code)
        guard let name = locale.localizedString(forLanguageCode: code), let first = name.first else { return nil }
        let endonym = String(first).uppercased(with: locale) + name.dropFirst()
        return endonym == displayName(for: code) ? nil : endonym
    }
}
