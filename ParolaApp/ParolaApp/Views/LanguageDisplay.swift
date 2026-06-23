import Foundation

enum LanguageDisplay {
    /// Localized, capitalized name for a transcript's language code, or nil when there's no
    /// real language: empty/whitespace, or the "unknown" sentinel that imports and YouTube-subs
    /// stamp on a transcript (the same sentinel `Format.cascadingFont` skips).
    static func name(for code: String?) -> String? {
        guard let raw = code else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !normalized.isEmpty, normalized != "unknown" else { return nil }
        if let localized = Locale.current.localizedString(forLanguageCode: normalized) {
            return localized.capitalized
        }
        return normalized.uppercased()
    }
}
