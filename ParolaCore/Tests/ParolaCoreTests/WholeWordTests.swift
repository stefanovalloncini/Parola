import Foundation
import Testing
@testable import ParolaCore

@Suite("Whole-word matching")
struct WholeWordTests {
    private func seg(_ text: String) -> TranscriptSegment {
        TranscriptSegment(id: 0, start: 0, end: 1, text: text)
    }

    private func apply(_ rule: FindReplaceRule, to text: String) -> String? {
        GlobalFindReplace.apply(rules: [rule], to: [seg(text)]).first?.text
    }

    private func transcript(_ texts: String...) -> Transcript {
        Transcript(
            segments: texts.enumerated().map { TranscriptSegment(id: $0.offset, start: 0, end: 1, text: $0.element) },
            language: "en",
            modelName: "tiny"
        )
    }

    @Test("a rule without the wholeWord key decodes as false")
    func decodeOld() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","find":"a","replace":"b","caseSensitive":false,"regex":false,"enabled":true}"#
        let rule = try JSONDecoder().decode(FindReplaceRule.self, from: Data(json.utf8))
        #expect(rule.wholeWord == false)
        #expect(rule.find == "a")
    }

    @Test("wholeWord round-trips")
    func roundTrip() throws {
        let rule = FindReplaceRule(find: "cat", replace: "dog", wholeWord: true)
        let decoded = try JSONDecoder().decode(FindReplaceRule.self, from: JSONEncoder().encode(rule))
        #expect(decoded == rule)
        #expect(decoded.wholeWord)
    }

    @Test("cat leaves category alone")
    func category() {
        let rule = FindReplaceRule(find: "cat", replace: "dog", wholeWord: true)
        #expect(apply(rule, to: "the category and the cat.") == "the category and the dog.")
    }

    @Test("case folding follows caseSensitive")
    func caseFolding() {
        let insensitive = FindReplaceRule(find: "cat", replace: "dog", wholeWord: true)
        #expect(apply(insensitive, to: "Cat sat") == "dog sat")
        let sensitive = FindReplaceRule(find: "cat", replace: "dog", caseSensitive: true, wholeWord: true)
        #expect(apply(sensitive, to: "Cat cat") == "Cat dog")
    }

    @Test("a punctuation edge is not anchored")
    func punctuationEdge() {
        let rule = FindReplaceRule(find: "(c)", replace: "©", wholeWord: true)
        #expect(apply(rule, to: "foo(c)bar") == "foo©bar")
    }

    @Test("digits count as word characters, underscore does not")
    func digitsAndUnderscore() {
        let rule = FindReplaceRule(find: "v2", replace: "two", wholeWord: true)
        #expect(apply(rule, to: "v2 v22 xv2 v2_x") == "two v22 xv2 two_x")
    }

    @Test("a precomposed rule matches a decomposed café")
    func decomposedText() {
        let rule = FindReplaceRule(find: "caf\u{E9}", replace: "bar", wholeWord: true)
        #expect(apply(rule, to: "un cafe\u{301} e un caf\u{E9}") == "un bar e un bar")
    }

    @Test("a decomposed rule matches a precomposed café")
    func decomposedRule() {
        let rule = FindReplaceRule(find: "cafe\u{301}", replace: "bar", wholeWord: true)
        #expect(apply(rule, to: "un caf\u{E9}s e un caf\u{E9}") == "un caf\u{E9}s e un bar")
    }

    @Test("regex wins over wholeWord")
    func regexWins() {
        let rule = FindReplaceRule(find: "ca.", replace: "X", regex: true, wholeWord: true)
        #expect(apply(rule, to: "category") == "Xegory")
    }

    @Test("a bare e does not match inside a decomposed é")
    func baseLetterOfDecomposed() {
        let rule = FindReplaceRule(find: "cafe", replace: "bar", wholeWord: true)
        #expect(apply(rule, to: "cafe\u{301} cafe") == "cafe\u{301} bar")
    }

    @Test("dictation literalWord keeps its exact-scalar matching")
    func literalWordUnchanged() {
        let rule = ReplacementRule(find: "caf\u{E9}", replace: "bar", match: .literalWord(underscoreIsWordCharacter: false), caseSensitive: false)
        #expect(rule.compiled()?.apply(to: "cafe\u{301}") == "cafe\u{301}")
    }

    @Test("term pack carries wholeWord through pack and merge")
    func termPack() throws {
        let rules = [FindReplaceRule(find: "cat", replace: "dog", wholeWord: true)]
        let pack = TermPackIO.pack(from: rules, name: "n", locale: "en")
        #expect(pack.rules.first?.wholeWord == true)
        let decoded = try TermPackIO.decode(TermPackIO.encode(pack))
        #expect(decoded == pack)
        let merged = TermPackIO.merge(pack: decoded, into: [])
        #expect(merged.first?.wholeWord == true)
    }

    @Test("a pack rule without the key is not whole-word")
    func termPackOld() throws {
        let json = #"{"name":"n","locale":"en","version":1,"rules":[{"find":"a","replace":"b"}]}"#
        #expect(try TermPackIO.decode(Data(json.utf8)).rules.first?.wholeWord == false)
    }

    @Test("merge key includes wholeWord")
    func mergeKey() {
        let existing = [FindReplaceRule(find: "cat", replace: "dog")]
        let pack = TermPack(name: "n", locale: "en", rules: [
            TermPackRule(find: "cat", replace: "dog"),
            TermPackRule(find: "cat", replace: "dog", wholeWord: true),
        ])
        let merged = TermPackIO.merge(pack: pack, into: existing)
        #expect(merged.count == 2)
        #expect(merged.last?.wholeWord == true)
    }

    @Test("findMatches with wholeWords skips embedded hits")
    func findMatches() {
        let t = transcript("cat category cat.", "concat Cat")
        #expect(t.findMatches("cat").count == 5)
        #expect(t.findMatches("cat", wholeWords: true).count == 3)
        #expect(t.findMatches("cat", caseSensitive: true, wholeWords: true).count == 2)
    }

    @Test("containsMatch honors wholeWords")
    func containsMatch() {
        let t = transcript("category")
        #expect(Transcript.containsMatch("cat", in: t.segments))
        #expect(!Transcript.containsMatch("cat", wholeWords: true, in: t.segments))
    }

    @Test("replacingAll honors wholeWords")
    func replacingAll() {
        let t = transcript("cat category").replacingAll("cat", with: "dog", wholeWords: true)
        #expect(t.segments[0].text == "dog category")
    }

    @Test("emoji and modifiers are not word characters")
    func emoji() {
        let t = transcript("ok👍🏽 ok👍 😀ok")
        #expect(t.findMatches("ok", wholeWords: true).count == 3)
    }

    @Test("a decomposed accent counts as part of the word")
    func combiningMark() {
        let t = transcript("cafe\u{301} cafe")
        #expect(t.findMatches("cafe", wholeWords: true).count == 1)
    }

    @Test("a punctuation edge in the query is not anchored")
    func punctuationQuery() {
        #expect(transcript("foo(c)bar").findMatches("(c)", wholeWords: true).count == 1)
    }

    @Test("a rule does not match after a decomposed accent")
    func markBeforeMatch() {
        let rule = FindReplaceRule(find: "fono", replace: "X", wholeWord: true)
        #expect(apply(rule, to: "tele\u{301}fono fono") == "tele\u{301}fono X")
        let sume = FindReplaceRule(find: "sum\u{E9}", replace: "X", wholeWord: true)
        #expect(apply(sume, to: "re\u{301}sume\u{301}") == "re\u{301}sume\u{301}")
    }

    @Test("a vowel sign is part of the word")
    func devanagari() {
        let rule = FindReplaceRule(find: "ताब", replace: "X", wholeWord: true)
        #expect(apply(rule, to: "किताब") == "किताब")
    }

    @Test("a rule with regex and wholeWord from a pack is stored as regex")
    func mergeNormalizes() {
        let pack = TermPack(name: "n", locale: "en", rules: [TermPackRule(find: "a.", replace: "b", regex: true, wholeWord: true)])
        let merged = TermPackIO.merge(pack: pack, into: [])
        #expect(merged.first?.regex == true)
        #expect(merged.first?.wholeWord == false)
    }

    @Test("the Find bar judges Characters, not UTF-16 units")
    func characterBoundaries() {
        let t = transcript("re\u{301}sume\u{301}")
        #expect(t.findMatches("sum\u{E9}").count == 1)
        #expect(t.findMatches("sum\u{E9}", wholeWords: true).isEmpty)
        let math = transcript("\u{1D400}cat cat")
        #expect(math.findMatches("cat").count == 2)
        #expect(math.findMatches("cat", wholeWords: true).count == 1)
    }
}
