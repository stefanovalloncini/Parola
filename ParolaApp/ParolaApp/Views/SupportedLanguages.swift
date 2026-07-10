import Foundation

/// The one language table shared by every picker (toolbar, Transcription Defaults,
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
        let fallback = fallbackNames[code] ?? code
        guard let localized = Locale.current.localizedString(forLanguageCode: code) else {
            return fallback
        }
        return localized.capitalized(with: Locale.current)
    }

    static var options: [(code: String, name: String)] {
        codes.map { ($0, displayName(for: $0)) }
    }
}
