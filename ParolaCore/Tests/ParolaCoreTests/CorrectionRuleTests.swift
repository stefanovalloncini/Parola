import Foundation
import Testing
@testable import ParolaCore
@testable import ParolaDictation

@Suite("Correction rule set")
struct CorrectionRuleTests {
    struct SingleRuleCase: Sendable {
        let name: String
        let from: String
        let to: String
        let enabled: Bool
        let caseSensitive: Bool
        let input: String
        let expected: String

        init(
            _ name: String,
            from: String,
            to: String,
            enabled: Bool = true,
            caseSensitive: Bool = false,
            input: String,
            expected: String
        ) {
            self.name = name
            self.from = from
            self.to = to
            self.enabled = enabled
            self.caseSensitive = caseSensitive
            self.input = input
            self.expected = expected
        }
    }

    @Test("empty rules return text unchanged")
    func empty() {
        let set = CorrectionRuleSet(rules: [])
        #expect(set.apply(to: "hello world") == "hello world")
    }

    @Test("a whitespace-only rule never fires")
    func whitespaceOnlyRuleInert() {
        let set = CorrectionRuleSet(rules: [CorrectionRule(from: "  ", to: "X")])
        #expect(set.apply(to: "hello  world") == "hello  world")
    }

    @Test(
        "applies a single rule",
        arguments: [
            SingleRuleCase(
                "disabled rules are skipped",
                from: "foo", to: "bar", enabled: false,
                input: "foo baz", expected: "foo baz"
            ),
            SingleRuleCase(
                "case-insensitive by default",
                from: "foo", to: "FOO",
                input: "Foo and FOO and foo", expected: "FOO and FOO and FOO"
            ),
            SingleRuleCase(
                "case-sensitive when requested",
                from: "Foo", to: "FOO", caseSensitive: true,
                input: "Foo and foo", expected: "FOO and foo"
            ),
            SingleRuleCase(
                "respects word boundaries",
                from: "cat", to: "feline",
                input: "the cat in the catalog", expected: "the feline in the catalog"
            ),
            SingleRuleCase(
                "empty from is ignored",
                from: "", to: "X",
                input: "hello", expected: "hello"
            ),
            SingleRuleCase(
                "regex metacharacters are escaped",
                from: "c++", to: "C++",
                input: "i love c++", expected: "i love C++"
            ),
            SingleRuleCase(
                "replacement metacharacters are literal",
                from: "foo", to: "$1bar",
                input: "say foo please", expected: "say $1bar please"
            ),
            SingleRuleCase(
                "leading-punctuation rule matches when attached to a word",
                from: "...", to: "…",
                input: "wait... really...", expected: "wait… really…"
            ),
            SingleRuleCase(
                "punctuation-only rule matches between words",
                from: "->", to: "→",
                input: "if a->b then b->c", expected: "if a→b then b→c"
            ),
            SingleRuleCase(
                "bracketed punctuation rule matches attached to a word",
                from: "(c)", to: "©",
                input: "Acme(c) 2026", expected: "Acme© 2026"
            ),
            SingleRuleCase(
                "word-leading rule still respects the leading boundary",
                from: "c++", to: "C++",
                input: "abc++ and c++", expected: "abc++ and C++"
            ),
        ]
    )
    func singleRule(_ testCase: SingleRuleCase) {
        let set = CorrectionRuleSet(rules: [
            CorrectionRule(
                from: testCase.from,
                to: testCase.to,
                caseSensitive: testCase.caseSensitive,
                enabled: testCase.enabled
            )
        ])
        #expect(set.apply(to: testCase.input) == testCase.expected)
    }

    @Test("multiple rules apply in order")
    func multipleRules() {
        let set = CorrectionRuleSet(rules: [
            CorrectionRule(from: "q three", to: "Q3"),
            CorrectionRule(from: "kpi", to: "KPI")
        ])
        #expect(set.apply(to: "q three KPI vs kpi") == "Q3 KPI vs KPI")
    }
}
