import Foundation
import Testing
import ParolaCore
@testable import Parola

@MainActor
@Suite("Karaoke word highlighting")
struct KaraokeTextTests {
    private func word(_ id: String, _ text: String) -> WordTiming {
        WordTiming(id: id, word: text, start: 0, end: 0, probability: 1)
    }

    @Test("joins plain words with single spaces, no trailing space")
    func joinsPlainWords() {
        let words = [word("0-0", "ciao"), word("0-1", "mondo")]
        let attr = SegmentCard.karaokeText(words: words, activeWordID: nil)
        #expect(String(attr.characters) == "ciao mondo")
    }

    @Test("keeps an apostrophe elision tail attached")
    func keepsApostropheElision() {
        let words = [word("0-0", "l"), word("0-1", "'altro"), word("0-2", "che")]
        let attr = SegmentCard.karaokeText(words: words, activeWordID: nil)
        #expect(String(attr.characters) == "l'altro che")
    }

    @Test("keeps a typographic apostrophe elision tail attached")
    func keepsTypographicElision() {
        let words = [word("0-0", "c"), word("0-1", "\u{2019}\u{00E8}")]
        let attr = SegmentCard.karaokeText(words: words, activeWordID: nil)
        #expect(String(attr.characters) == "c\u{2019}\u{00E8}")
    }

    @Test("a trailing-apostrophe word still spaces before the next word")
    func trailingApostropheWordSpacesNormally() {
        let words = [word("0-0", "un"), word("0-1", "po'"), word("0-2", "qua")]
        let attr = SegmentCard.karaokeText(words: words, activeWordID: nil)
        #expect(String(attr.characters) == "un po' qua")
    }

    @Test("highlighting the active word restyles it without changing the text")
    func highlightsActiveWord() {
        let words = [word("0-0", "ciao"), word("0-1", "mondo")]
        let plain = SegmentCard.karaokeText(words: words, activeWordID: nil)
        let highlighted = SegmentCard.karaokeText(words: words, activeWordID: "0-1")
        #expect(String(plain.characters) == String(highlighted.characters))
        #expect(plain != highlighted)
    }
}
