import Foundation

public struct FindReplaceRule: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public var find: String
    public var replace: String
    public var caseSensitive: Bool
    public var regex: Bool
    public var wholeWord: Bool
    public var enabled: Bool

    public init(
        id: UUID = UUID(),
        find: String,
        replace: String,
        caseSensitive: Bool = false,
        regex: Bool = false,
        wholeWord: Bool = false,
        enabled: Bool = true
    ) {
        self.id = id
        self.find = find
        self.replace = replace
        self.caseSensitive = caseSensitive
        self.regex = regex
        self.wholeWord = wholeWord
        self.enabled = enabled
    }

    /// Regex and whole words exclude each other: turning one on turns the other off.
    public mutating func setRegex(_ on: Bool) {
        regex = on
        if on { wholeWord = false }
    }

    public mutating func setWholeWord(_ on: Bool) {
        wholeWord = on
        if on { regex = false }
    }

    private enum CodingKeys: String, CodingKey {
        case id, find, replace, caseSensitive, regex, wholeWord, enabled
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        find = try c.decode(String.self, forKey: .find)
        replace = try c.decode(String.self, forKey: .replace)
        caseSensitive = try c.decode(Bool.self, forKey: .caseSensitive)
        regex = try c.decode(Bool.self, forKey: .regex)
        wholeWord = try c.decodeIfPresent(Bool.self, forKey: .wholeWord) ?? false
        enabled = try c.decode(Bool.self, forKey: .enabled)
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

    /// Applies the enabled rules to each segment's text in order, then collapses the whitespace
    /// runs a deletion rule leaves behind (so removing a mid-sentence word doesn't leave a double
    /// space) and trims the edges. A segment left empty is dropped, so a deletion rule can't leave
    /// a blank cue/line behind. A segment whose text actually changes loses its word timings, which
    /// no longer line up with the rewritten text (karaoke falls back to the char-based estimate).
    public static func apply(
        rules: [FindReplaceRule],
        to segments: [TranscriptSegment]
    ) -> [TranscriptSegment] {
        let active = rules.filter(\.enabled).map(\.replacementRule).filter { !$0.isBlank }
        guard !active.isEmpty else { return segments }
        // A regex that doesn't compile changes nothing, but its segments are still tidied below.
        let compiled = active.compactMap { $0.compiled() }
        return segments.compactMap { seg in
            var copy = seg
            let replaced = compiled.reduce(seg.text) { current, rule in
                rule.apply(to: current)
            }
            copy.text = replaced.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            guard !copy.text.isEmpty else { return nil }
            if copy.text != seg.text { copy.words = nil }
            return copy
        }
    }
}

extension FindReplaceRule {
    /// Foundation's substring search for a plain rule, so "café" still finds a decomposed "café".
    var replacementRule: ReplacementRule {
        let match: ReplacementRule.Match = regex ? .regex : wholeWord ? .wholeWord : .substring
        return ReplacementRule(find: find, replace: replace, match: match, caseSensitive: caseSensitive)
    }
}
