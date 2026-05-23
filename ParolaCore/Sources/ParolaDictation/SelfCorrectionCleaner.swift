import Foundation

/// Strips spoken self-correction markers like "Scratch that, …", "Wait, no, …", and the
/// parenthetical "X, I mean, Y" hedge. Operates conservatively: any pattern that would
/// require resolving which preceding phrase to drop is left alone.
public struct SelfCorrectionCleaner: TextPostProcessor, Sendable {
    public init() {}

    public func process(_ text: String) async -> String { Self.clean(text) }

    public static func clean(_ text: String) -> String {
        var out = text
        for pattern in Self.prefixDrops {
            out = applyPattern(pattern.regex, in: out, with: pattern.replacement)
        }
        return out
    }

    private struct Rule {
        let regex: NSRegularExpression
        let replacement: String
    }

    private static func makeRule(_ pattern: String, _ replacement: String) -> Rule {
        let regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        return Rule(regex: regex, replacement: replacement)
    }

    private static let prefixDrops: [Rule] = [
        makeRule(#"(^|(?<=[\.!?]\s))scratch that[,\.!?]\s+"#, "$1"),
        makeRule(#"(^|(?<=[\.!?]\s))wait,?\s+no[,\.!?]\s+"#, "$1"),
        makeRule(#",\s+I mean,?\s+"#, ", "),
        makeRule(#",\s+I meant,?\s+"#, ", "),
    ]

    private static func applyPattern(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}
