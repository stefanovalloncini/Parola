import Foundation
import os

/// A find-and-replace rule as dictation corrections, snippets and transcript rules all compile it; `match` keeps each one's semantics.
package struct ReplacementRule: Sendable {
    package enum Match: Sendable {
        /// Foundation's substring search, as `replacingOccurrences(of:with:options:)` runs it.
        case substring
        /// `find` taken literally, anchored at each edge that is a letter or digit, or `_` when `underscoreIsWordCharacter`.
        case literalWord(underscoreIsWordCharacter: Bool)
        /// `find` is a regular expression and `replace` a template.
        case regex
    }

    package var find: String
    package var replace: String
    package var match: Match
    package var caseSensitive: Bool

    package init(find: String, replace: String, match: Match, caseSensitive: Bool) {
        self.find = find
        self.replace = replace
        self.match = match
        self.caseSensitive = caseSensitive
    }

    /// Whether the rule has anything to find: a blank `find` would rewrite every gap between words.
    package var isBlank: Bool {
        find.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Nil for a blank rule and for a pattern that doesn't compile.
    package func compiled() -> CompiledReplacement? {
        guard !isBlank else { return nil }
        switch match {
        case .substring:
            return CompiledReplacement(rule: self, regex: nil)
        case .regex:
            return RegexCache.shared.regex(find, caseSensitive: caseSensitive).map { CompiledReplacement(rule: self, regex: $0) }
        case .literalWord(let underscoreIsWordCharacter):
            guard let first = find.first, let last = find.last else { return nil }
            let isWord: (Character) -> Bool = { $0.isLetter || $0.isNumber || (underscoreIsWordCharacter && $0 == "_") }
            let wordClass = underscoreIsWordCharacter ? "[\\p{L}\\p{N}_]" : "[\\p{L}\\p{N}]"
            // An anchor on a punctuation edge ("...", "(c)") could never match next to a letter, so only word edges get one.
            let lead = isWord(first) ? "(?<!\(wordClass))" : ""
            let trail = isWord(last) ? "(?!\(wordClass))" : ""
            let pattern = lead + NSRegularExpression.escapedPattern(for: find) + trail
            return RegexCache.shared.regex(pattern, caseSensitive: caseSensitive).map { CompiledReplacement(rule: self, regex: $0) }
        }
    }
}

package struct CompiledReplacement: Sendable {
    private let rule: ReplacementRule
    private let regex: NSRegularExpression?
    private let template: String

    fileprivate init(rule: ReplacementRule, regex: NSRegularExpression?) {
        self.rule = rule
        self.regex = regex
        self.template = Self.template(for: rule.replace, match: rule.match)
    }

    package func apply(to text: String) -> String {
        apply(to: text, template: template)
    }

    /// For a replacement written afresh on each use, such as a snippet's placeholders: the pattern stays compiled.
    package func apply(to text: String, replacement: String) -> String {
        apply(to: text, template: Self.template(for: replacement, match: rule.match))
    }

    private func apply(to text: String, template: String) -> String {
        guard let regex else {
            let options: NSString.CompareOptions = rule.caseSensitive ? [] : [.caseInsensitive]
            return text.replacingOccurrences(of: rule.find, with: template, options: options)
        }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    private static func template(for replacement: String, match: ReplacementRule.Match) -> String {
        guard case .literalWord = match else { return replacement }
        return NSRegularExpression.escapedTemplate(for: replacement)
    }
}

/// Patterns compiled once per process: a Unicode-class lookaround costs ~0.3 ms, and rule lists rebuild on every edit.
private final class RegexCache: Sendable {
    static let shared = RegexCache()

    /// Bytes, not the `String`: Swift equates "café" with "cafe\u{301}", ICU matches them as different patterns.
    private struct Key: Hashable {
        let pattern: [UInt8]
        let caseSensitive: Bool
    }

    /// Enough for every rule a user keeps; past it the cache starts over rather than growing with each edit.
    private static let limit = 512

    private let entries = OSAllocatedUnfairLock<[Key: NSRegularExpression?]>(initialState: [:])

    func regex(_ pattern: String, caseSensitive: Bool) -> NSRegularExpression? {
        let key = Key(pattern: Array(pattern.utf8), caseSensitive: caseSensitive)
        if let cached = entries.withLock({ $0[key] }) { return cached }
        let compiled = try? NSRegularExpression(pattern: pattern, options: caseSensitive ? [] : [.caseInsensitive])
        entries.withLock { entries in
            if entries.count >= Self.limit { entries.removeAll(keepingCapacity: true) }
            entries[key] = compiled
        }
        return compiled
    }
}
