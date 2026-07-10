import Foundation

public struct CorrectionRule: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public var from: String
    public var to: String
    public var caseSensitive: Bool
    public var enabled: Bool

    public init(
        id: UUID = UUID(),
        from: String,
        to: String,
        caseSensitive: Bool = false,
        enabled: Bool = true
    ) {
        self.id = id
        self.from = from
        self.to = to
        self.caseSensitive = caseSensitive
        self.enabled = enabled
    }

    public enum CodingKeys: String, CodingKey {
        case id, from, to, caseSensitive, enabled
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        from = try c.decode(String.self, forKey: .from)
        to = try c.decode(String.self, forKey: .to)
        caseSensitive = try c.decodeIfPresent(Bool.self, forKey: .caseSensitive) ?? false
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

public struct CorrectionRuleSet: TextPostProcessor, Sendable {
    public func process(_ text: String) async -> String { apply(to: text) }

    public let rules: [CorrectionRule]
    private let compiled: [Compiled]

    private struct Compiled: Sendable {
        let regex: NSRegularExpression
        let template: String
    }

    public init(rules: [CorrectionRule]) {
        self.rules = rules
        self.compiled = rules.compactMap { rule -> Compiled? in
            guard rule.enabled, !rule.from.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let escaped = NSRegularExpression.escapedPattern(for: rule.from)
            guard !escaped.isEmpty, let first = rule.from.first, let last = rule.from.last else { return nil }
            let isWord: (Character) -> Bool = { $0.isLetter || $0.isNumber }
            // Anchor an edge only when it's a word char — a boundary anchor on a punctuation edge ("...", "(c)") could never match next to a letter.
            let lead = isWord(first) ? "(?<![\\p{L}\\p{N}])" : ""
            let trail = isWord(last) ? "(?![\\p{L}\\p{N}])" : ""
            let bounded = "\(lead)\(escaped)\(trail)"
            var options: NSRegularExpression.Options = []
            if !rule.caseSensitive { options.insert(.caseInsensitive) }
            guard let regex = try? NSRegularExpression(pattern: bounded, options: options) else {
                return nil
            }
            return Compiled(regex: regex, template: NSRegularExpression.escapedTemplate(for: rule.to))
        }
    }

    public func apply(to text: String) -> String {
        guard !compiled.isEmpty else { return text }
        var out = text
        for rule in compiled {
            let range = NSRange(out.startIndex..., in: out)
            out = rule.regex.stringByReplacingMatches(in: out, range: range, withTemplate: rule.template)
        }
        return out
    }

}
