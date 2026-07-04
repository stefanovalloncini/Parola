import Foundation
import Testing
@testable import ParolaCore

@Suite("Italian orthography normalization")
struct ItalianOrthographyTests {
    private func seg(_ id: Int, _ text: String, words: [WordTiming]? = nil) -> TranscriptSegment {
        TranscriptSegment(id: id, start: Double(id), end: Double(id) + 1, text: text, words: words)
    }

    @Test("grave-accented perché is corrected to acute for Italian")
    func correctsPerche() {
        let input = [seg(0, "non so perchè")]
        let out = ItalianOrthography.apply(to: input, language: "it")
        #expect(out.map(\.text) == ["non so perché"])
    }

    @Test("the whole -ché conjunction family is corrected")
    func correctsFamily() {
        let input = [seg(0, "poichè benchè finchè sicchè giacchè nonchè anzichè cosicchè purchè affinchè")]
        let out = ItalianOrthography.apply(to: input, language: "it")
        #expect(out.first?.text == "poiché benché finché sicché giacché nonché anziché cosicché purché affinché")
    }

    @Test("the non-conjunction -ché members are corrected from the grave misspelling")
    func correctsExtendedFamily() {
        let input = [
            seg(0, "non è un granchè"),
            seg(1, "checchè se ne dica"),
            seg(2, "andava tutto bene sennonchè ha iniziato a piovere"),
        ]
        let out = ItalianOrthography.apply(to: input, language: "it")
        #expect(out.map(\.text) == [
            "non è un granché",
            "checché se ne dica",
            "andava tutto bene sennonché ha iniziato a piovere",
        ])
    }

    @Test("capitalization of the matched word is preserved")
    func preservesCase() {
        let input = [seg(0, "Perchè no"), seg(1, "PERCHÈ")]
        let out = ItalianOrthography.apply(to: input, language: "it")
        #expect(out.map(\.text) == ["Perché no", "PERCHÉ"])
    }

    @Test("already-correct acute forms are unchanged")
    func leavesAcuteAlone() {
        let input = [seg(0, "perché sì")]
        let out = ItalianOrthography.apply(to: input, language: "it")
        #expect(out.map(\.text) == ["perché sì"])
    }

    @Test("legitimately grave words are not touched")
    func leavesGraveWordsAlone() {
        let input = [seg(0, "il caffè è pronto cioè adesso")]
        let out = ItalianOrthography.apply(to: input, language: "it")
        #expect(out.map(\.text) == ["il caffè è pronto cioè adesso"])
    }

    @Test("non-Italian transcripts are left unchanged")
    func skipsNonItalian() {
        let input = [seg(0, "perchè")]
        #expect(ItalianOrthography.apply(to: input, language: "en").map(\.text) == ["perchè"])
        #expect(ItalianOrthography.apply(to: input, language: "fr").map(\.text) == ["perchè"])
        #expect(ItalianOrthography.apply(to: input, language: nil).map(\.text) == ["perchè"])
    }

    @Test("it-IT region code still corrects")
    func handlesRegionCode() {
        let input = [seg(0, "perchè")]
        #expect(ItalianOrthography.apply(to: input, language: "it-IT").map(\.text) == ["perché"])
    }

    @Test("word-level tokens are corrected to match the segment text")
    func correctsWordTokens() {
        let words = [
            WordTiming(id: "0-0", word: "so", start: 0, end: 0.5, probability: 1),
            WordTiming(id: "0-1", word: "perchè", start: 0.5, end: 1, probability: 1),
        ]
        let out = ItalianOrthography.apply(to: [seg(0, "so perchè", words: words)], language: "it")
        #expect(out.first?.words?.map(\.word) == ["so", "perché"])
        #expect(out.first?.text == "so perché")
    }

    @Test("correction is bounded to whole words")
    func wholeWordOnly() {
        let input = [seg(0, "operchè perchè")]
        let out = ItalianOrthography.apply(to: input, language: "it")
        #expect(out.first?.text == "operchè perché")
    }

    @Test("bare po is corrected to the apostrophe truncation")
    func correctsTruncatedPo() {
        let input = [seg(0, "esiste un po da capire")]
        let out = ItalianOrthography.apply(to: input, language: "it")
        #expect(out.map(\.text) == ["esiste un po' da capire"])
    }

    @Test("po at the end of a segment is corrected")
    func correctsTrailingPo() {
        let input = [seg(0, "aspetta un po")]
        let out = ItalianOrthography.apply(to: input, language: "it")
        #expect(out.first?.text == "aspetta un po'")
    }

    @Test("an already-apostrophed po is left alone")
    func leavesApostrophedPoAlone() {
        let straight = [seg(0, "un po' di pane")]
        let curly = [seg(0, "un po\u{2019} di pane")]
        #expect(ItalianOrthography.apply(to: straight, language: "it").first?.text == "un po' di pane")
        #expect(ItalianOrthography.apply(to: curly, language: "it").first?.text == "un po\u{2019} di pane")
    }

    @Test("the capitalised river Po is never apostrophed")
    func leavesRiverPoAlone() {
        let input = [seg(0, "il fiume Po è lungo"), seg(1, "Po è un fiume")]
        let out = ItalianOrthography.apply(to: input, language: "it")
        #expect(out.map(\.text) == ["il fiume Po è lungo", "Po è un fiume"])
    }

    @Test("po inside a longer word is not touched")
    func leavesPoInWordsAlone() {
        let input = [seg(0, "dopo poco a Napoli")]
        let out = ItalianOrthography.apply(to: input, language: "it")
        #expect(out.first?.text == "dopo poco a Napoli")
    }

    @Test("word-level po token is corrected")
    func correctsPoWordToken() {
        let words = [
            WordTiming(id: "0-0", word: "un", start: 0, end: 0.5, probability: 1),
            WordTiming(id: "0-1", word: "po", start: 0.5, end: 1, probability: 1),
        ]
        let out = ItalianOrthography.apply(to: [seg(0, "un po", words: words)], language: "it")
        #expect(out.first?.words?.map(\.word) == ["un", "po'"])
        #expect(out.first?.text == "un po'")
    }

    @Test("bare po is only corrected for Italian")
    func truncationIsItalianOnly() {
        let input = [seg(0, "type po then enter")]
        #expect(ItalianOrthography.apply(to: input, language: "en").first?.text == "type po then enter")
    }

    @Test("grave-accented pò is corrected to the apostrophe truncation")
    func correctsGravePo() {
        let input = [seg(0, "esiste un pò da capire"), seg(1, "aspetta un pò")]
        let out = ItalianOrthography.apply(to: input, language: "it")
        #expect(out.map(\.text) == ["esiste un po' da capire", "aspetta un po'"])
    }

    @Test("an already-apostrophed pò is left alone")
    func leavesApostrophedGravePoAlone() {
        let straight = [seg(0, "un pò' di pane")]
        let curly = [seg(0, "un pò\u{2019} di pane")]
        #expect(ItalianOrthography.apply(to: straight, language: "it").first?.text == "un pò' di pane")
        #expect(ItalianOrthography.apply(to: curly, language: "it").first?.text == "un pò\u{2019} di pane")
    }

    @Test("the capitalised river Pò is never apostrophed")
    func leavesCapitalisedGravePoAlone() {
        let input = [seg(0, "il fiume Pò è lungo"), seg(1, "Pò è un fiume")]
        let out = ItalianOrthography.apply(to: input, language: "it")
        #expect(out.map(\.text) == ["il fiume Pò è lungo", "Pò è un fiume"])
    }

    @Test("pò inside a longer word is not touched")
    func leavesGravePoInWordsAlone() {
        let input = [seg(0, "il dopòscuola")]
        let out = ItalianOrthography.apply(to: input, language: "it")
        #expect(out.first?.text == "il dopòscuola")
    }

    @Test("word-level pò token is corrected")
    func correctsGravePoWordToken() {
        let words = [
            WordTiming(id: "0-0", word: "un", start: 0, end: 0.5, probability: 1),
            WordTiming(id: "0-1", word: "pò", start: 0.5, end: 1, probability: 1),
        ]
        let out = ItalianOrthography.apply(to: [seg(0, "un pò", words: words)], language: "it")
        #expect(out.first?.words?.map(\.word) == ["un", "po'"])
        #expect(out.first?.text == "un po'")
    }

    @Test("all-caps grave form is still corrected")
    func correctsAllCapsGrave() {
        let out = ItalianOrthography.apply(to: [seg(0, "PERCHÈ NO")], language: "it")
        #expect(out.first?.text == "PERCHÉ NO")
    }

    @Test("text without accents or po returns unchanged")
    func leavesPlainTextUntouched() {
        let text = "una frase del tutto normale senza correzioni"
        let out = ItalianOrthography.apply(to: [seg(0, text)], language: "it")
        #expect(out.first?.text == text)
    }

    @Test("grave family and truncation both fire in one segment")
    func correctsMixedSegment() {
        let out = ItalianOrthography.apply(to: [seg(0, "perchè un pò così")], language: "it")
        #expect(out.first?.text == "perché un po' così")
    }
}
