import Foundation

/// Corrects a narrow set of objective Italian orthographic errors that ASR engines emit: the
/// `-ché` family written with a grave accent ("perchè" → "perché"), and the bare
/// truncation of "poco" written without its apostrophe — both the plain "po" and the common
/// misspelling "pò" ("un po", "un pò" → "un po'"). Every correction targets a form that is always
/// wrong in standard Italian — legitimately-grave words (`caffè`, `cioè`) and the capitalised
/// river "Po" are never matched. Applied only when the language is Italian.
public enum ItalianOrthography {
    public static func apply(to segments: [TranscriptSegment], language: String?) -> [TranscriptSegment] {
        guard isItalian(language) else { return segments }
        return segments.map { segment in
            var segment = segment
            segment.text = correct(segment.text)
            if let words = segment.words {
                segment.words = words.map { word in
                    var word = word
                    word.word = correct(word.word)
                    return word
                }
            }
            return segment
        }
    }

    static func isItalian(_ language: String?) -> Bool {
        guard let code = language?.lowercased() else { return false }
        return code == "it" || code.hasPrefix("it-") || code.hasPrefix("it_")
    }

    private static let acuteForms = [
        "perché", "poiché", "affinché", "benché", "finché", "sicché", "giacché",
        "nonché", "anziché", "cosicché", "fuorché", "purché", "dopodiché",
        "macché", "dacché", "allorché", "acciocché", "sennonché",
        "granché", "checché", "ché",
    ]

    private static let acuteByGrave: [String: String] = Dictionary(
        uniqueKeysWithValues: acuteForms.map { (String($0.dropLast()) + "è", $0) }
    )

    /// One alternation over every grave form: each alternative is a whole word, so no two can
    /// overlap and a single scan finds what one regex per form used to.
    private static let graveFamily: NSRegularExpression? = {
        let alternatives = acuteByGrave.keys.sorted().map(NSRegularExpression.escapedPattern(for:))
        let pattern = "\\b(?:" + alternatives.joined(separator: "|") + ")\\b"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    private static let truncations: [(regex: NSRegularExpression, replacement: String)] = {
        guard let po = try? NSRegularExpression(pattern: "\\bp[oò]\\b(?![\u{27}\u{2019}])") else { return [] }
        return [(po, "po'")]
    }()

    static func correct(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        // Every grave-family match contains è/È and every truncation match contains po/pò,
        // so this prefilter lets most text skip the regex pipeline entirely.
        let mayHaveGrave = text.contains("è") || text.contains("È")
        let mayHaveTruncation = text.contains("po") || text.contains("pò")
        guard mayHaveGrave || mayHaveTruncation else { return text }
        var result = text
        if mayHaveGrave, let graveFamily {
            result = replaceMatches(of: graveFamily, in: result) { acuteByGrave[$0.lowercased()] }
        }
        if mayHaveTruncation {
            for (regex, replacement) in truncations {
                result = replaceMatches(of: regex, in: result) { _ in replacement }
            }
        }
        return result
    }

    private static func replaceMatches(
        of regex: NSRegularExpression,
        in text: String,
        with replacement: (String) -> String?
    ) -> String {
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            let matched = ns.substring(with: match.range)
            guard let target = replacement(matched) else { continue }
            let cased = caseMatched(target, like: matched)
            result = (result as NSString).replacingCharacters(in: match.range, with: cased)
        }
        return result
    }

    private static func caseMatched(_ replacement: String, like matched: String) -> String {
        if matched != matched.lowercased(), matched == matched.uppercased() {
            return replacement.uppercased()
        }
        if let first = matched.first, first.isUppercase {
            return replacement.prefix(1).uppercased() + replacement.dropFirst()
        }
        return replacement
    }
}
