import Foundation
import ParolaCore

enum LanguageDisplay {
    /// Localized, capitalized name for a transcript's language code, or nil when there's no
    /// real language: empty/whitespace, or the "unknown" sentinel that imports and YouTube-subs
    /// stamp on a transcript (the same sentinel `Format.cascadingFont` skips).
    static func name(for code: String?) -> String? {
        guard let normalized = realCode(code) else { return nil }
        if let localized = Locale.current.localizedString(forLanguageCode: normalized) {
            return localized.capitalized
        }
        return normalized.uppercased()
    }

    /// The name inside a sentence: Italian doesn't capitalise language names, so "(italiano)" there.
    static func midSentenceName(for code: String?, locale: Locale = .current) -> String? {
        guard let normalized = realCode(code) else { return nil }
        guard let localized = locale.localizedString(forLanguageCode: normalized) else { return normalized.uppercased() }
        return locale.language.languageCode?.identifier == "it" ? localized.lowercased(with: locale) : localized.capitalized(with: locale)
    }

    /// Uppercased code for a compact language badge ("IT", "EN"), or nil for the same
    /// no-real-language cases as ``name(for:)`` — so a transcript stamped with the "unknown"
    /// sentinel shows no badge instead of a literal "UNKNOWN".
    static func code(for code: String?) -> String? {
        realCode(code)?.uppercased()
    }

    private static func realCode(_ code: String?) -> String? {
        SpokenLanguage.realCode(code)?.lowercased()
    }
}
