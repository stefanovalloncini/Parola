import Foundation

/// Fixes the lone first-person pronoun "i" — uppercases it when surrounded by word
/// boundaries (including contractions like "i'm", "i've", "i'll", "i'd"). Leaves
/// inflected forms inside other words alone (e.g. "kim", "icon", "ipad").
///
/// English-only: lone "i" is a word in other languages ("i" is the Italian plural
/// article), so the rule runs only for an explicit English `language`. Nil means
/// auto-detect — the text could be any language, so the rule is skipped.
public enum PronounCapitalizer {
    public static func applyTo(_ text: String, language: String?) -> String {
        guard appliesToEnglish(language) else { return text }
        return Self.regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: "I$1"
        )
    }

    private static func appliesToEnglish(_ language: String?) -> Bool {
        guard let language, !language.isEmpty else { return false }
        return language.lowercased().hasPrefix("en")
    }

    private static let regex: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"(?<![\p{L}\p{N}])i('(?:m|ve|ll|d|re))?(?![\p{L}\p{N}])"#,
            options: [.caseInsensitive]
        )
    }()
}
