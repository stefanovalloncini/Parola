import Foundation

/// Fixes the lone first-person pronoun "i" — uppercases it when surrounded by word
/// boundaries (including contractions like "i'm", "i've", "i'll", "i'd"). Leaves
/// inflected forms inside other words alone (e.g. "kim", "icon", "ipad").
public enum PronounCapitalizer {
    public static func applyTo(_ text: String) -> String {
        Self.regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: "I$1"
        )
    }

    private static let regex: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"(?<![\p{L}\p{N}])i('(?:m|ve|ll|d|re))?(?![\p{L}\p{N}])"#,
            options: [.caseInsensitive]
        )
    }()
}
