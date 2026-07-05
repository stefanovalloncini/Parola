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

    private func timedWord(_ id: String, _ text: String, start: Double, end: Double) -> WordTiming {
        WordTiming(id: id, word: text, start: start, end: end, probability: 1)
    }

    @Test("every word run links to its start time, separators carry no link")
    func wordRunsCarrySeekLinks() {
        let words = [
            timedWord("0-0", "ciao", start: 1.5, end: 2.0),
            timedWord("0-1", "mondo", start: 2.0, end: 2.75),
        ]
        let attr = SegmentCard.karaokeText(words: words, activeWordID: nil)
        let links = attr.runs.compactMap(\.link)
        #expect(links == [
            URL(string: "parola-seek-time://1.5"),
            URL(string: "parola-seek-time://2.0"),
        ])
        let unlinked = attr.runs.filter { $0.link == nil }
        #expect(unlinked.count == 1)
    }

    @Test("word runs keep an explicit foreground and no underline despite the link")
    func wordRunsStyledAgainstLinkTint() {
        let words = [
            timedWord("0-0", "ciao", start: 0, end: 0.5),
            timedWord("0-1", "mondo", start: 0.5, end: 1.0),
        ]
        let attr = SegmentCard.karaokeText(words: words, activeWordID: "0-1")
        for run in attr.runs where run.link != nil {
            #expect(run.foregroundColor != nil)
            #expect(run.underlineStyle == nil)
        }
        // Theme colors are dynamic providers, unequal across instances — compare runs, not swatches.
        let active = attr.runs.first { $0.link == URL(string: "parola-seek-time://0.5") }
        let inactive = attr.runs.first { $0.link == URL(string: "parola-seek-time://0.0") }
        #expect(active?.foregroundColor != nil)
        #expect(inactive?.foregroundColor != nil)
        #expect(active?.foregroundColor != inactive?.foregroundColor)
    }
}
