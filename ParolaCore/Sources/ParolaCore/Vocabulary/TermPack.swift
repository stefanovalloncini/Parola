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
        var seen = Set(out.map(key))
        for rule in pack.rules where !rule.find.isEmpty {
            let candidate = FindReplaceRule(
                find: rule.find,
                replace: rule.replace,
                caseSensitive: rule.caseSensitive,
                regex: rule.regex,
                enabled: true
            )
            guard seen.insert(key(candidate)).inserted else { continue }
            out.append(candidate)
        }
        return out
    }
}

/// Built-in term packs shipped inside `ParolaCore.Resources/TermPacks/`.
/// Available to every frontend — macOS app, iOS app, CLI, MCP server.
public enum BundledTermPacks {
    public static let identifiers: [String] = ["tech-terms-en", "tech-terms-it"]

    public static func load(_ identifier: String) -> TermPack? {
        let bundle = Bundle.module
        guard let url = bundle.url(forResource: identifier, withExtension: "json", subdirectory: "TermPacks")
                ?? bundle.url(forResource: identifier, withExtension: "json")
        else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? TermPackIO.decode(data)
    }

    public static func all() -> [TermPack] {
        identifiers.compactMap(load(_:))
    }

    public static func matching(locale: Locale) -> [TermPack] {
        guard let code = locale.language.languageCode?.identifier else { return [] }
        return all().filter { $0.locale == code }
    }
}
