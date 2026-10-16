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
        ("—", ""),
        ("-uh-", "uh"),
        ("えっと。", "えっと"),
        ("ええ！？", "ええ"),
        ("uh,", "uh"),
        ("、はい、", "はい")
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
        "Subscribe", "See you next time", "Music", "Applause", "Watching",
        "Thanks for listening.", "See you next week.", "Grazie a tutti.", "Grazie per l'attenzione.", "Alla prossima!",
        "Muchas gracias.", "Merci beaucoup.", "Vielen Dank.", "Muito obrigado.", "Большое спасибо.",
        "ありがとうございました", "谢谢", "谢谢大家", "Thank you for listening.", "Thank you very much."
    ])
    func speechStays(text: String) {
        #expect(kept([text], rules: SuggestedIgnoredPhrases.rules()) == [text])
    }

    @Test("hallucinated lines and tags are dropped", arguments: [
        "Thanks for watching!", "Thanks for watching.", "Thank you for watching.", "[Music]", "[MUSIC]",
        "♪♪", "(music)", "[BLANK_AUDIO]", "Grazie per la visione!", "¡Suscríbete!", "Danke fürs Zuschauen!",
        "ご視聴ありがとうございました", "Продолжение следует...",
        "Vielen Dank für's Zuschauen.", "[Musica]", "(upbeat music)", "Редактор субтитров А.Синецкая Корректор А.Егорова",
        "チャンネル登録をよろしくお願いします!", "请不吝点赞订阅转发打赏支持明镜与点点栏目",
        "請不吝點贊訂閱轉發打賞支持明鏡與點點欄目"
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

    @Test("a tag next to speech is dropped and the speech stays, end to end on WhisperKit", arguments: [
        "[Music]", "(upbeat music)", "♪", "♪♪"
    ])
    func tagNextToSpeechSurvivesTheMerge(tag: String) async {
        let transcript = Transcript(
            segments: [
                TranscriptSegment(id: 0, start: 0, end: 3, text: tag),
                TranscriptSegment(id: 1, start: 3.4, end: 6, text: "Hello everyone and welcome back"),
                TranscriptSegment(id: 2, start: 6.2, end: 8, text: "to the show.")
            ],
            language: "en",
            modelName: "openai_whisper-tiny"
        )
        let finished = await TranscriptFinisher.finish(
            transcript, engine: .whisperKit, options: TranscriptionOptions(), audioURL: nil
        )
        let kept = IgnoredSegments.apply(rules: SuggestedIgnoredPhrases.rules(), to: finished.segments)
        #expect(kept.map(\.text) == ["Hello everyone and welcome back to the show."])
    }

    @Test("a tag after speech is not glued to it either")
    func tagAfterSpeech() async {
        let transcript = Transcript(
            segments: [
                TranscriptSegment(id: 0, start: 0, end: 2, text: "So that is it"),
                TranscriptSegment(id: 1, start: 2.2, end: 4, text: "[Music]")
            ],
            language: "en",
            modelName: "openai_whisper-tiny"
        )
        let finished = await TranscriptFinisher.finish(
            transcript, engine: .whisperKit, options: TranscriptionOptions(), audioURL: nil
        )
        #expect(finished.segments.map(\.text) == ["So that is it", "[Music]"])
    }
}
