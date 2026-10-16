import Foundation
import Testing
@testable import ParolaCore

@Suite("Suggested ignored phrases")
struct SuggestedIgnoredPhrasesTests {
    private func seg(_ id: Int, _ text: String) -> TranscriptSegment {
        TranscriptSegment(id: id, start: Double(id), end: Double(id) + 1, text: text)
    }

    private func kept(_ texts: [String], rules: [IgnoredSegmentRule]) -> [String] {
        let segments = texts.enumerated().map { seg($0.offset, $0.element) }
        return IgnoredSegments.apply(rules: rules, to: segments).map(\.text)
    }

    @Test("the normalizer trims case, whitespace and surrounding punctuation", arguments: [
        ("Uh.", "uh"),
        ("  UH!  ", "uh"),
        ("Thanks for watching!", "thanks for watching"),
        ("¡Suscríbete!", "suscríbete"),
        ("...uh...", "uh"),
        ("[Music]", "[music]"),
        ("♪♪", ""),
        ("  ", ""),
        ("—", "")
    ])
    func normalizerTable(input: String, expected: String) {
        #expect(IgnoredSegments.normalized(input) == expected)
    }

    @Test("a plain rule also drops the segment with punctuation around it")
    func punctuationInsensitive() {
        let rules = [IgnoredSegmentRule(pattern: "uh")]
        #expect(kept(["Uh.", "uh huh", "Uh…"], rules: rules) == ["uh huh"])
    }

    @Test("a punctuation-only rule drops segments that are only punctuation")
    func punctuationOnlyRule() {
        let rules = [IgnoredSegmentRule(pattern: "♪")]
        #expect(kept(["♪♪", "♪", "hello ♪"], rules: rules) == ["hello ♪"])
    }

    @Test("a blank rule matches nothing")
    func blankRule() {
        let rules = [IgnoredSegmentRule(pattern: "  ")]
        #expect(kept(["♪", "hello"], rules: rules) == ["♪", "hello"])
    }

    @Test("the list has no duplicates once normalized")
    func noDuplicates() {
        let keys = SuggestedIgnoredPhrases.defaults.map(IgnoredSegments.normalized)
        #expect(Set(keys).count == keys.count)
    }

    @Test("the list holds no built-in credit line")
    func noBuiltInOverlap() {
        for phrase in SuggestedIgnoredPhrases.defaults {
            #expect(!HallucinationPhrases.matchSet.contains(IgnoredSegments.normalized(phrase)), "\(phrase)")
        }
    }

    @Test("real whole-segment speech never matches the list", arguments: [
        "Thank you.", "Thanks.", "Thank you so much.", "Bye.", "Bye-bye.", "Okay.", "you", "Yes.", "Hello.",
        "Grazie.", "Grazie mille.", "Ciao.", "Gracias.", "Merci.", "Danke.", "Obrigado.", "Спасибо.",
        "Subscribe", "See you next time", "Music", "Applause", "Watching"
    ])
    func speechStays(text: String) {
        #expect(kept([text], rules: SuggestedIgnoredPhrases.rules()) == [text])
    }

    @Test("hallucinated lines and tags are dropped", arguments: [
        "Thanks for watching!", "Thanks for watching.", "Thank you for watching.", "[Music]", "[MUSIC]",
        "♪♪", "(music)", "[BLANK_AUDIO]", "Grazie per la visione!", "¡Suscríbete!", "Danke fürs Zuschauen!",
        "ご視聴ありがとうございました", "Продолжение следует..."
    ])
    func hallucinationsDrop(text: String) {
        #expect(kept([text], rules: SuggestedIgnoredPhrases.rules()).isEmpty)
    }

    @Test("rules() gives fresh enabled rules")
    func rulesAreEnabled() {
        let rules = SuggestedIgnoredPhrases.rules()
        #expect(rules.count == SuggestedIgnoredPhrases.defaults.count)
        #expect(rules.allSatisfy { $0.enabled })
        #expect(Set(rules.map(\.id)).count == rules.count)
    }

    @Test("missing skips phrases already covered, enabled or not, by normalized pattern")
    func missingSkipsCovered() {
        let existing = [
            IgnoredSegmentRule(pattern: "thanks for watching"),
            IgnoredSegmentRule(pattern: "[MUSIC]", enabled: false),
            IgnoredSegmentRule(pattern: "♪♪"),
            IgnoredSegmentRule(pattern: "uh")
        ]
        let added = SuggestedIgnoredPhrases.missing(from: existing).map(\.pattern)
        #expect(added.count == SuggestedIgnoredPhrases.defaults.count - 3)
        #expect(!added.contains("Thanks for watching!"))
        #expect(!added.contains("[Music]"))
        #expect(!added.contains("♪"))
    }

    @Test("missing ignores blank rules and is empty when everything is there")
    func missingEdges() {
        #expect(SuggestedIgnoredPhrases.missing(from: [IgnoredSegmentRule(pattern: "")]).count == SuggestedIgnoredPhrases.defaults.count)
        #expect(SuggestedIgnoredPhrases.missing(from: SuggestedIgnoredPhrases.rules()).isEmpty)
    }
}
