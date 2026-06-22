import Foundation
import Testing
@testable import ParolaCore

@Suite("Global find & replace")
struct GlobalFindReplaceTests {
    private func seg(_ id: Int, _ text: String) -> TranscriptSegment {
        TranscriptSegment(id: id, start: Double(id), end: Double(id) + 1, text: text)
    }

    @Test("empty rules return segments unchanged")
    func empty() {
        let input = [seg(0, "Hello")]
        let out = GlobalFindReplace.apply(rules: [], to: input)
        #expect(out.map(\.text) == ["Hello"])
    }

    @Test("simple substring replace")
    func simpleReplace() {
        let rule = FindReplaceRule(find: "world", replace: "Parola")
        let out = GlobalFindReplace.apply(rules: [rule], to: [seg(0, "Hello world")])
        #expect(out.first?.text == "Hello Parola")
    }

    @Test("case-insensitive by default")
    func caseInsensitive() {
        let rule = FindReplaceRule(find: "hello", replace: "Hi")
        let out = GlobalFindReplace.apply(rules: [rule], to: [seg(0, "Hello world")])
        #expect(out.first?.text == "Hi world")
    }

    @Test("case-sensitive only matches same case")
    func caseSensitive() {
        let rule = FindReplaceRule(find: "hello", replace: "Hi", caseSensitive: true)
        let out = GlobalFindReplace.apply(rules: [rule], to: [seg(0, "Hello world")])
        #expect(out.first?.text == "Hello world")
    }

    @Test("disabled rule keeps text unchanged")
    func disabled() {
        let rule = FindReplaceRule(find: "world", replace: "X", enabled: false)
        let out = GlobalFindReplace.apply(rules: [rule], to: [seg(0, "Hello world")])
        #expect(out.first?.text == "Hello world")
    }

    @Test("empty find is a no-op")
    func emptyFind() {
        let rule = FindReplaceRule(find: "", replace: "X")
        let out = GlobalFindReplace.apply(rules: [rule], to: [seg(0, "Hello")])
        #expect(out.first?.text == "Hello")
    }

    @Test("regex rule replaces matches with template")
    func regex() {
        let rule = FindReplaceRule(find: "h(e)llo", replace: "h$1y", regex: true)
        let out = GlobalFindReplace.apply(rules: [rule], to: [seg(0, "hello world")])
        #expect(out.first?.text == "hey world")
    }

    @Test("rules apply in order")
    func order() {
        let r1 = FindReplaceRule(find: "Parola", replace: "Word")
        let r2 = FindReplaceRule(find: "Word", replace: "Verb")
        let out = GlobalFindReplace.apply(rules: [r1, r2], to: [seg(0, "Hi Parola")])
        #expect(out.first?.text == "Hi Verb")
    }

    @Test("a segment emptied by replacement is dropped")
    func dropsEmptied() {
        let rule = FindReplaceRule(find: "ok", replace: "")
        let out = GlobalFindReplace.apply(rules: [rule], to: [seg(0, "ok"), seg(1, "Hello world"), seg(2, "Ok")])
        #expect(out.map(\.text) == ["Hello world"])
    }

    @Test("a segment left whitespace-only by replacement is dropped")
    func dropsWhitespaceOnly() {
        let rule = FindReplaceRule(find: "uh", replace: "")
        let out = GlobalFindReplace.apply(rules: [rule], to: [seg(0, " uh "), seg(1, "real")])
        #expect(out.map(\.text) == ["real"])
    }

    @Test("collapses a double space left by a mid-segment deletion")
    func collapsesInternalWhitespace() {
        let rule = FindReplaceRule(find: "um", replace: "")
        let out = GlobalFindReplace.apply(rules: [rule], to: [seg(0, "well um okay")])
        #expect(out.first?.text == "well okay")
    }

    @Test("trims edge whitespace left by a deletion")
    func trimsEdgeWhitespace() {
        let leadRule = FindReplaceRule(find: "um", replace: "")
        let leading = GlobalFindReplace.apply(rules: [leadRule], to: [seg(0, "um well okay")])
        #expect(leading.first?.text == "well okay")
        let trailRule = FindReplaceRule(find: "okay", replace: "")
        let trailing = GlobalFindReplace.apply(rules: [trailRule], to: [seg(0, "well okay")])
        #expect(trailing.first?.text == "well")
    }

    @Test("rule round-trips through JSON")
    func jsonRoundTrip() throws {
        let rule = FindReplaceRule(find: "foo", replace: "bar", caseSensitive: true, regex: true)
        let data = try JSONEncoder().encode([rule])
        let decoded = try JSONDecoder().decode([FindReplaceRule].self, from: data)
        #expect(decoded.first?.find == "foo")
        #expect(decoded.first?.replace == "bar")
        #expect(decoded.first?.caseSensitive == true)
        #expect(decoded.first?.regex == true)
    }

    @Test("validate returns nil for a literal rule")
    func validateLiteral() {
        let rule = FindReplaceRule(find: "hello", replace: "hi")
        #expect(GlobalFindReplace.validate(rule) == nil)
    }

    @Test("validate returns nil for a well-formed regex")
    func validateGoodRegex() {
        let rule = FindReplaceRule(find: "h(e)llo", replace: "h$1y", regex: true)
        #expect(GlobalFindReplace.validate(rule) == nil)
    }

    @Test("validate returns a reason for an invalid regex")
    func validateBadRegex() {
        let rule = FindReplaceRule(find: "h(ello", replace: "bye", regex: true)
        #expect(GlobalFindReplace.validate(rule) != nil)
    }
}
