import Foundation

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

    /// Uppercased code for a compact language badge ("IT", "EN"), or nil for the same
    /// no-real-language cases as ``name(for:)`` — so a transcript stamped with the "unknown"
    /// sentinel shows no badge instead of a literal "UNKNOWN".
    static func code(for code: String?) -> String? {
        realCode(code)?.uppercased()
    }

    private static func realCode(_ code: String?) -> String? {
        guard let raw = code else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !normalized.isEmpty, normalized != "unknown" else { return nil }
        return normalized
    }
}
