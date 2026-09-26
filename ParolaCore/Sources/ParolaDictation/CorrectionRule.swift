import Foundation
import ParolaCore

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
    private let compiled: [CompiledReplacement]

    public init(rules: [CorrectionRule]) {
        self.rules = rules
        self.compiled = rules.compactMap { $0.enabled ? $0.replacementRule.compiled() : nil }
    }

    public func apply(to text: String) -> String {
        compiled.reduce(text) { $1.apply(to: $0) }
    }
}

extension CorrectionRule {
    /// Literal and word-bounded, where `_` is not a word character.
    var replacementRule: ReplacementRule {
        ReplacementRule(find: from, replace: to, match: .literalWord(underscoreIsWordCharacter: false), caseSensitive: caseSensitive)
    }
}
