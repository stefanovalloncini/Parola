import Foundation
import Testing
import ParolaCore
@testable import ParolaSpeech

@Suite("RenderText")
struct RenderTextTests {
    private func capabilities(expandsNumbers: Bool, maxUnitChars: Int = 400) -> SpeechRendererCapabilities {
        SpeechRendererCapabilities(
            languages: [], expandsNumbers: expandsNumbers, usesNeuralEngine: false, nominalRTF: 0, maxUnitChars: maxUnitChars
        )
    }

    @Test("a renderer that can't expand numbers gets them spelled out; one that can gets the text as written")
    func normalisesOnlyWhenNeeded() {
        let spelled = RenderText.pieces(of: "I have 3 cats.", language: "en", capabilities: capabilities(expandsNumbers: false))
        let raw = RenderText.pieces(of: "I have 3 cats.", language: "en", capabilities: capabilities(expandsNumbers: true))
        #expect(spelled == ["I have three cats."])
        #expect(raw == ["I have 3 cats."])
    }

    @Test("non-speech is stripped for a renderer that expands numbers and for one that does not", arguments: [true, false])
    func stripsNonSpeechForEveryRenderer(expandsNumbers: Bool) {
        let pieces = RenderText.pieces(
            of: "So [Music] see https://example.com 🎉 now.", language: "en",
            capabilities: capabilities(expandsNumbers: expandsNumbers)
        )
        #expect(pieces == ["So see now."])
    }

    @Test("a unit with nothing to say has no pieces", arguments: [
        ("🎉 🎉", false), ("[Music]", false), ("https://example.com/a", false), ("  \n ", true), ("🎉", true), ("…", true),
    ])
    func nothingToSay(text: String, expandsNumbers: Bool) {
        #expect(RenderText.pieces(of: text, language: "en", capabilities: capabilities(expandsNumbers: expandsNumbers)).isEmpty)
    }

    @Test("surrounding whitespace and newlines are trimmed")
    func trims() {
        #expect(RenderText.pieces(of: "\n  Hello there.  \n", language: "en", capabilities: capabilities(expandsNumbers: true)) == ["Hello there."])
    }

    @Test("a 1,000-character Chinese run with no marks is cut into pieces of at most 70 that join back")
    func longChineseRun() {
        let text = String(repeating: "这是一个没有标点的长句子", count: 84).prefix(1_000)
        let pieces = RenderText.split(String(text), maxLength: 70)
        #expect(text.count == 1_000)
        #expect(pieces.count == 15)
        #expect(pieces.allSatisfy { $0.count <= 70 })
        #expect(pieces.joined() == String(text))
    }

    @Test("Chinese clause marks are cut after, before any hard cut")
    func chineseMarks() {
        let first = String(repeating: "中", count: 30) + "，"
        let second = String(repeating: "文", count: 30) + "。"
        let third = String(repeating: "字", count: 30) + "、"
        let pieces = RenderText.split(first + second + third + String(repeating: "句", count: 20), maxLength: 70)
        #expect(pieces == [first + second, third + String(repeating: "句", count: 20)])
    }

    @Test("a 300-character URL is cut hard into pieces of at most 70 that join back")
    func longURL() {
        let url = "https://example.com/" + String(repeating: "abcdefghij", count: 28)
        let pieces = RenderText.split(url, maxLength: 70)
        #expect(url.count == 300)
        #expect(pieces.count == 5)
        #expect(pieces.allSatisfy { $0.count <= 70 })
        #expect(pieces.joined() == url)
    }

    @Test("a clause mark followed by a space wins over a later space")
    func clauseBeforeSpace() {
        let pieces = RenderText.split("alpha beta, gamma delta epsilon zeta", maxLength: 20)
        #expect(pieces == ["alpha beta,", "gamma delta epsilon", "zeta"])
    }

    @Test("a comma inside a number is not a clause mark")
    func numberComma() {
        let pieces = RenderText.split("The total came to 1,000,000 dollars today", maxLength: 24)
        #expect(pieces == ["The total came to", "1,000,000 dollars today"])
    }

    @Test("with no mark and no space the cut falls between grapheme clusters", arguments: [
        String(repeating: "e\u{301}", count: 100),
        String(repeating: "👨‍👩‍👧", count: 40),
        String(repeating: "🇮🇹", count: 40),
    ])
    func graphemeBoundaries(text: String) {
        let pieces = RenderText.split(text, maxLength: 7)
        let firstCharacter = text.first.map(String.init)
        #expect(pieces.joined() == text)
        #expect(pieces.allSatisfy { $0.count <= 7 })
        #expect(pieces.allSatisfy { $0.first.map(String.init) == firstCharacter })
    }
}
