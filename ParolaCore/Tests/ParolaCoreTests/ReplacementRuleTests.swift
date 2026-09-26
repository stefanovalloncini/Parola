import Foundation
import Testing
@testable import ParolaCore
@testable import ParolaDictation

/// The three rule engines as they were before they shared one compiler, kept to pin that each still matches what it matched.
private enum LegacyEngines {
    static func corrections(_ rules: [CorrectionRule], _ text: String) -> String {
        let compiled = rules.compactMap { rule -> (NSRegularExpression, String)? in
            guard rule.enabled, !rule.from.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let escaped = NSRegularExpression.escapedPattern(for: rule.from)
            guard !escaped.isEmpty, let first = rule.from.first, let last = rule.from.last else { return nil }
            let isWord: (Character) -> Bool = { $0.isLetter || $0.isNumber }
            let lead = isWord(first) ? "(?<![\\p{L}\\p{N}])" : ""
            let trail = isWord(last) ? "(?![\\p{L}\\p{N}])" : ""
            var options: NSRegularExpression.Options = []
            if !rule.caseSensitive { options.insert(.caseInsensitive) }
            guard let regex = try? NSRegularExpression(pattern: "\(lead)\(escaped)\(trail)", options: options) else { return nil }
            return (regex, NSRegularExpression.escapedTemplate(for: rule.to))
        }
        var out = text
        for (regex, template) in compiled {
            out = regex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template)
        }
        return out
    }

    static func snippet(trigger: String, in text: String, with replacement: String) -> String {
        guard let first = trigger.first, let last = trigger.last else { return text }
        let escaped = NSRegularExpression.escapedPattern(for: trigger)
        let isWord: (Character) -> Bool = { $0.isLetter || $0.isNumber || $0 == "_" }
        let lead = isWord(first) ? "(?<![\\p{L}\\p{N}_])" : ""
        let trail = isWord(last) ? "(?![\\p{L}\\p{N}_])" : ""
        guard let regex = try? NSRegularExpression(pattern: "\(lead)\(escaped)\(trail)", options: [.caseInsensitive]) else {
            return text
        }
        let template = NSRegularExpression.escapedTemplate(for: replacement)
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    static func findReplace(_ rules: [FindReplaceRule], _ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        let active = rules.filter { $0.enabled && !$0.find.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !active.isEmpty else { return segments }
        func apply(_ rule: FindReplaceRule, _ text: String) -> String {
            if rule.regex {
                let options: NSRegularExpression.Options = rule.caseSensitive ? [] : [.caseInsensitive]
                guard let regex = try? NSRegularExpression(pattern: rule.find, options: options) else { return text }
                return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: rule.replace)
            }
            let options: NSString.CompareOptions = rule.caseSensitive ? [] : [.caseInsensitive]
            return text.replacingOccurrences(of: rule.find, with: rule.replace, options: options)
        }
        return segments.compactMap { seg in
            var copy = seg
            copy.text = active.reduce(seg.text) { apply($1, $0) }.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            guard !copy.text.isEmpty else { return nil }
            if copy.text != seg.text { copy.words = nil }
            return copy
        }
    }
}

private enum RuleFuzz {
    static let finds = [
        "foo", "Foo", "FOO", "foo bar", "foo_bar", "_foo", "foo_", "c++", "(c)", "...", "->", ":)", "brb!", "$1", "a\\b",
        "café", "cafe\u{301}", "Straße", "STRASSE", "ß", "İstanbul", "naïve", "👍", "👍🏽", "日本", "q three", "3.5", " foo",
        "foo ", "  ", "", "\\bfoo\\b", "(fo+)", "[", "f.o", "^foo", "foo$", "(?i)FOO", "x|y",
    ]
    static let replacements = ["bar", "", "$1", "\\", "$0!", "{x}", "Bar Baz", "ß", "🙂"]
    static let texts = [
        "foo bar foo_bar _foo foo_ food afoo FOO Foo", "c++ and abc++ (c) Acme(c) wait... a->b :) brb!",
        "café cafe\u{301} CAFÉ Straße STRASSE strasse ß SS", "İstanbul istanbul naïve NAÏVE 👍🏽 👍 日本語",
        "q three 3.5 $1 a\\b f.o fxo x y", "  spaced   out  ", "", "foo", "   ",
    ]
}

@Suite("Replacement rules")
struct ReplacementRuleTests {
    @Test("corrections match what their own compiler matched")
    func correctionsKeepTheirSemantics() {
        for find in RuleFuzz.finds {
            for replacement in RuleFuzz.replacements {
                for caseSensitive in [false, true] {
                    let rules = [CorrectionRule(from: find, to: replacement, caseSensitive: caseSensitive)]
                    let set = CorrectionRuleSet(rules: rules)
                    for text in RuleFuzz.texts {
                        #expect(set.apply(to: text) == LegacyEngines.corrections(rules, text), "\(find) → \(replacement) in \(text)")
                    }
                }
            }
        }
    }

    @Test("snippets match what their own compiler matched")
    func snippetsKeepTheirSemantics() async {
        for find in RuleFuzz.finds where !find.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            for replacement in RuleFuzz.replacements {
                let expander = SnippetExpander(snippets: [Snippet(trigger: find, replacement: replacement)])
                for text in RuleFuzz.texts {
                    let expected = LegacyEngines.snippet(trigger: find, in: text, with: replacement)
                    #expect(await expander.process(text) == expected, "\(find) → \(replacement) in \(text)")
                }
            }
        }
    }

    @Test("transcript rules match what their own compiler matched, literal and regex")
    func findReplaceKeepsItsSemantics() {
        let segments = RuleFuzz.texts.enumerated().map {
            TranscriptSegment(id: $0.offset, start: Double($0.offset), end: Double($0.offset) + 1, text: $0.element)
        }
        for find in RuleFuzz.finds {
            for replacement in RuleFuzz.replacements {
                for caseSensitive in [false, true] {
                    for regex in [false, true] {
                        let rules = [FindReplaceRule(find: find, replace: replacement, caseSensitive: caseSensitive, regex: regex)]
                        #expect(
                            GlobalFindReplace.apply(rules: rules, to: segments) == LegacyEngines.findReplace(rules, segments),
                            "\(find) → \(replacement) regex \(regex) caseSensitive \(caseSensitive)"
                        )
                    }
                }
            }
        }
    }

    @Test("rule lists apply in order on every surface")
    func listsApplyInOrder() async {
        let corrections = [
            CorrectionRule(from: "foo", to: "bar"), CorrectionRule(from: "bar", to: "baz", caseSensitive: true),
            CorrectionRule(from: "off", to: "x", enabled: false), CorrectionRule(from: "  ", to: "y"),
        ]
        let text = "foo Bar bar off"
        #expect(CorrectionRuleSet(rules: corrections).apply(to: text) == LegacyEngines.corrections(corrections, text))

        let expander = SnippetExpander(snippets: [
            Snippet(trigger: "me", replacement: "Stefano"), Snippet(trigger: "stefano", replacement: "S."),
            Snippet(trigger: "off", replacement: "x", enabled: false), Snippet(trigger: " ", replacement: "y"),
        ])
        #expect(await expander.process("hi me off") == "hi S. off")

        let rules = [
            FindReplaceRule(find: "(\\w+)@", replace: "$1 at ", regex: true), FindReplaceRule(find: "AT", replace: "@"),
            FindReplaceRule(find: "[", replace: "x", regex: true), FindReplaceRule(find: "gone", replace: "", enabled: false),
        ]
        let segments = [TranscriptSegment(id: 0, start: 0, end: 1, text: "mail me@home  now")]
        #expect(GlobalFindReplace.apply(rules: rules, to: segments) == LegacyEngines.findReplace(rules, segments))
    }

    @Test("each surface keeps its own word edges and case rules")
    func surfacesKeepTheirDifferences() async {
        #expect(CorrectionRuleSet(rules: [CorrectionRule(from: "foo", to: "X")]).apply(to: "foo_bar food") == "X_bar food")
        #expect(await SnippetExpander(snippets: [Snippet(trigger: "foo", replacement: "X")]).process("foo_bar food foo") == "foo_bar food X")
        let literal = [FindReplaceRule(find: "foo", replace: "X")]
        let segment = [TranscriptSegment(id: 0, start: 0, end: 1, text: "foo_bar food")]
        #expect(GlobalFindReplace.apply(rules: literal, to: segment).first?.text == "X_bar Xd")
        let composed = [FindReplaceRule(find: "café", replace: "X")]
        let decomposed = [TranscriptSegment(id: 0, start: 0, end: 1, text: "cafe\u{301}")]
        #expect(GlobalFindReplace.apply(rules: composed, to: decomposed).first?.text == "X")
        #expect(CorrectionRuleSet(rules: [CorrectionRule(from: "café", to: "X")]).apply(to: "cafe\u{301}") == "cafe\u{301}")
        #expect(await SnippetExpander(snippets: [Snippet(trigger: "Foo", replacement: "X")]).process("FOO") == "X")
    }

    @Test("canonically equal finds keep their own compiled patterns")
    func canonicallyEqualFindsStayApart() {
        let composed = CorrectionRuleSet(rules: [CorrectionRule(from: "café", to: "X")])
        let decomposed = CorrectionRuleSet(rules: [CorrectionRule(from: "cafe\u{301}", to: "X")])
        #expect(composed.apply(to: "café cafe\u{301}") == "X cafe\u{301}")
        #expect(decomposed.apply(to: "café cafe\u{301}") == "café X")
    }

    @Test("an invalid regex still tidies whitespace, as it always did")
    func invalidRegexStillTidies() {
        let rules = [FindReplaceRule(find: "[", replace: "x", regex: true)]
        let segments = [
            TranscriptSegment(id: 0, start: 0, end: 1, text: "  two   spaces "),
            TranscriptSegment(id: 1, start: 1, end: 2, text: "   "),
        ]
        #expect(GlobalFindReplace.apply(rules: rules, to: segments).map(\.text) == ["two spaces"])
    }
}
