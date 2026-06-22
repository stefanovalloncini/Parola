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
}
