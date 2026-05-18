import Foundation
import Testing
@testable import ParolaCore

@Suite("Correction rule set")
struct CorrectionRuleTests {
    @Test("empty rules return text unchanged")
    func empty() {
        let set = CorrectionRuleSet(rules: [])
        #expect(set.apply(to: "hello world") == "hello world")
    }

    @Test("disabled rules are skipped")
    func disabled() {
        let set = CorrectionRuleSet(rules: [
            CorrectionRule(from: "foo", to: "bar", enabled: false)
        ])
        #expect(set.apply(to: "foo baz") == "foo baz")
    }

    @Test("case-insensitive by default")
    func caseInsensitive() {
        let set = CorrectionRuleSet(rules: [
            CorrectionRule(from: "foo", to: "FOO")
        ])
        #expect(set.apply(to: "Foo and FOO and foo") == "FOO and FOO and FOO")
    }

    @Test("case-sensitive when requested")
    func caseSensitive() {
        let set = CorrectionRuleSet(rules: [
            CorrectionRule(from: "Foo", to: "FOO", caseSensitive: true)
        ])
        #expect(set.apply(to: "Foo and foo") == "FOO and foo")
    }

    @Test("respects word boundaries")
    func wordBoundary() {
        let set = CorrectionRuleSet(rules: [
            CorrectionRule(from: "cat", to: "feline")
        ])
        #expect(set.apply(to: "the cat in the catalog") == "the feline in the catalog")
    }

    @Test("multiple rules apply in order")
    func multipleRules() {
        let set = CorrectionRuleSet(rules: [
            CorrectionRule(from: "q three", to: "Q3"),
            CorrectionRule(from: "kpi", to: "KPI")
        ])
        #expect(set.apply(to: "q three KPI vs kpi") == "Q3 KPI vs KPI")
    }

    @Test("empty from is ignored")
    func emptyFrom() {
        let set = CorrectionRuleSet(rules: [
            CorrectionRule(from: "", to: "X")
        ])
        #expect(set.apply(to: "hello") == "hello")
    }

    @Test("regex metacharacters are escaped")
    func escapesRegex() {
        let set = CorrectionRuleSet(rules: [
            CorrectionRule(from: "c++", to: "C++")
        ])
        #expect(set.apply(to: "i love c++") == "i love C++")
    }

    @Test("replacement metacharacters are literal")
    func escapesReplacement() {
        let set = CorrectionRuleSet(rules: [
            CorrectionRule(from: "foo", to: "$1bar")
        ])
        #expect(set.apply(to: "say foo please") == "say $1bar please")
    }
}
