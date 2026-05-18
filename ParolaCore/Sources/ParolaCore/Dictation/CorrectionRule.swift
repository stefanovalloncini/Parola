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

    public init(rules: [CorrectionRule]) {
        self.rules = rules
    }

    public func apply(to text: String) -> String {
        var out = text
        for rule in rules where rule.enabled && !rule.from.isEmpty {
            out = Self.replaceWordBounded(
                pattern: rule.from,
                in: out,
                with: rule.to,
                caseSensitive: rule.caseSensitive
            )
        }
        return out
    }

    static func replaceWordBounded(
        pattern: String,
        in text: String,
        with replacement: String,
        caseSensitive: Bool
    ) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: pattern)
        guard !escaped.isEmpty else { return text }
        let bounded = "(?<![\\p{L}\\p{N}])\(escaped)(?![\\p{L}\\p{N}])"
        var options: NSRegularExpression.Options = []
        if !caseSensitive { options.insert(.caseInsensitive) }
        guard let regex = try? NSRegularExpression(pattern: bounded, options: options) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        let template = NSRegularExpression.escapedTemplate(for: replacement)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}
