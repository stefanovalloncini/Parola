import Foundation

public struct TermPack: Codable, Sendable, Hashable {
    public let name: String
    public let locale: String
    public let version: Int
    public let rules: [TermPackRule]

    public init(name: String, locale: String, version: Int = 1, rules: [TermPackRule]) {
        self.name = name
        self.locale = locale
        self.version = version
        self.rules = rules
    }
}

public struct TermPackRule: Codable, Sendable, Hashable {
    public let find: String
    public let replace: String
    public let caseSensitive: Bool
    public let regex: Bool

    public init(find: String, replace: String, caseSensitive: Bool = false, regex: Bool = false) {
        self.find = find
        self.replace = replace
        self.caseSensitive = caseSensitive
        self.regex = regex
    }
}

public enum TermPackIO {
    public static func encode(_ pack: TermPack) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(pack)
    }

    public static func decode(_ data: Data) throws -> TermPack {
        try JSONDecoder().decode(TermPack.self, from: data)
    }

    public static func pack(from rules: [FindReplaceRule], name: String, locale: String) -> TermPack {
        let packRules = rules.map { rule in
            TermPackRule(
                find: rule.find,
                replace: rule.replace,
                caseSensitive: rule.caseSensitive,
                regex: rule.regex
            )
        }
        return TermPack(name: name, locale: locale, rules: packRules)
    }

    public static func merge(pack: TermPack, into existing: [FindReplaceRule]) -> [FindReplaceRule] {
        var out = existing
        let key: (FindReplaceRule) -> String = { "\($0.find)|\($0.caseSensitive)|\($0.regex)" }
        let existingKeys = Set(out.map(key))
        for rule in pack.rules where !rule.find.isEmpty {
            let candidate = FindReplaceRule(
                find: rule.find,
                replace: rule.replace,
                caseSensitive: rule.caseSensitive,
                regex: rule.regex,
                enabled: true
            )
            if !existingKeys.contains(key(candidate)) {
                out.append(candidate)
            }
        }
        return out
    }
}
