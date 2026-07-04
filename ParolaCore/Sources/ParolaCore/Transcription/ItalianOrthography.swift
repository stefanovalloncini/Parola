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

    private static let corrections: [(regex: NSRegularExpression, acute: String)] = acuteForms.compactMap { acute in
        guard let last = acute.last, last == "é" else { return nil }
        let grave = acute.dropLast() + "è"
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: String(grave)) + "\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        return (regex, acute)
    }

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
        if mayHaveGrave {
            for (regex, acute) in corrections {
                result = replaceMatches(of: regex, in: result, with: acute)
            }
        }
        if mayHaveTruncation {
            for (regex, replacement) in truncations {
                result = replaceMatches(of: regex, in: result, with: replacement)
            }
        }
        return result
    }

    private static func replaceMatches(of regex: NSRegularExpression, in text: String, with acute: String) -> String {
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            let matched = ns.substring(with: match.range)
            let cased = caseMatched(acute, like: matched)
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
