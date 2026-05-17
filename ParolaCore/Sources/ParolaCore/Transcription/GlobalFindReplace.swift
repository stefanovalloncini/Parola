import Foundation

public struct FindReplaceRule: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public var find: String
    public var replace: String
    public var caseSensitive: Bool
    public var regex: Bool
    public var enabled: Bool

    public init(
        id: UUID = UUID(),
        find: String,
        replace: String,
        caseSensitive: Bool = false,
        regex: Bool = false,
        enabled: Bool = true
    ) {
        self.id = id
        self.find = find
        self.replace = replace
        self.caseSensitive = caseSensitive
        self.regex = regex
        self.enabled = enabled
    }
}

public enum GlobalFindReplace {
    /// Returns nil if the rule is valid for use; otherwise the user-facing reason.
    public static func validate(_ rule: FindReplaceRule) -> String? {
        guard rule.regex else { return nil }
        let options: NSRegularExpression.Options = rule.caseSensitive ? [] : [.caseInsensitive]
        do {
            _ = try NSRegularExpression(pattern: rule.find, options: options)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    public static func apply(
        rules: [FindReplaceRule],
        to segments: [TranscriptSegment]
    ) -> [TranscriptSegment] {
        let active = rules.filter { $0.enabled && !$0.find.isEmpty }
        guard !active.isEmpty else { return segments }
        return segments.map { seg in
            var copy = seg
            copy.text = active.reduce(seg.text) { current, rule in
                applyRule(rule, to: current)
            }
            return copy
        }
    }

    private static func applyRule(_ rule: FindReplaceRule, to text: String) -> String {
        if rule.regex {
            let options: NSRegularExpression.Options = rule.caseSensitive ? [] : [.caseInsensitive]
            guard let re = try? NSRegularExpression(pattern: rule.find, options: options) else {
                return text
            }
            let range = NSRange(text.startIndex..., in: text)
            return re.stringByReplacingMatches(in: text, range: range, withTemplate: rule.replace)
        } else {
            let options: NSString.CompareOptions = rule.caseSensitive ? [] : [.caseInsensitive]
            return text.replacingOccurrences(of: rule.find, with: rule.replace, options: options)
        }
    }
}
