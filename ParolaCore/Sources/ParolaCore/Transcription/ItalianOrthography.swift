import Foundation

/// Corrects a narrow set of objective Italian orthographic errors that ASR engines emit. Today
/// that's the `-ché` conjunction family written with a grave accent ("perchè") where standard
/// Italian requires the acute ("perché"). The word list is closed and every entry is always
/// acute, so there are no false positives — `caffè`, `cioè`, `è` and other legitimately-grave
/// words are never matched. Applied only when the transcript language is Italian.
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
        "macché", "dacché", "allorché", "acciocché", "ché",
    ]

    private static let corrections: [(regex: NSRegularExpression, acute: String)] = acuteForms.compactMap { acute in
        guard let last = acute.last, last == "é" else { return nil }
        let grave = acute.dropLast() + "è"
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: String(grave)) + "\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        return (regex, acute)
    }

    static func correct(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = text
        for (regex, acute) in corrections {
            result = replaceMatches(of: regex, in: result, with: acute)
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
