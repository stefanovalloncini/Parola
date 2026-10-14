import Foundation
import SwiftUI
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

    @Test("the active word takes the transcript face at emphasis, its neighbours none")
    func activeWordTakesTheEmphasisTier() {
        let words = [
            timedWord("0-0", "ciao", start: 0, end: 0.5),
            timedWord("0-1", "mondo", start: 0.5, end: 1.0),
        ]
        let attr = SegmentCard.karaokeText(words: words, activeWordID: "0-1")
        let active = attr.runs.first { $0.link == URL(string: "parola-seek-time://0.5") }
        let inactive = attr.runs.first { $0.link == URL(string: "parola-seek-time://0.0") }
        #expect(active?.font == DS.Font.transcriptEmphasis(serif: false))
        #expect(inactive?.font == nil)
    }

    @Test("the active word follows the serif setting")
    func activeWordFollowsSerif() {
        let words = [timedWord("0-0", "ciao", start: 0, end: 0.5)]
        let attr = SegmentCard.karaokeText(words: words, activeWordID: "0-0", serif: true)
        #expect(attr.runs.first?.font == DS.Font.transcriptEmphasis(serif: true))
        #expect(attr.runs.first?.font != DS.Font.transcriptEmphasis(serif: false))
    }

    // MARK: - Synthetic karaoke

    private func cumulative(_ tokens: [String]) -> [Int] {
        var running = 0
        return tokens.map {
            running += $0.count
            return running
        }
    }

    @Test("tokenizing drops the whitespace between words")
    func syntheticTokensDropWhitespace() {
        #expect(SegmentCard.syntheticKaraokeTokens("  ciao \n mondo  ") == ["ciao", "mondo"])
        #expect(SegmentCard.syntheticKaraokeTokens("   ").isEmpty)
    }

    @Test("the spoken token walks from the first to the last across the segment")
    func syntheticIndexWalksTokens() {
        let counts = cumulative(["uno", "due", "tre"])
        #expect(SegmentCard.syntheticKaraokeIndex(cumulativeChars: counts, progress: 0) == 0)
        #expect(SegmentCard.syntheticKaraokeIndex(cumulativeChars: counts, progress: 0.5) == 1)
        #expect(SegmentCard.syntheticKaraokeIndex(cumulativeChars: counts, progress: 1) == 2)
    }

    @Test("progress outside 0…1 clamps to the first and last token")
    func syntheticIndexClamps() {
        let counts = cumulative(["uno", "due", "tre"])
        #expect(SegmentCard.syntheticKaraokeIndex(cumulativeChars: counts, progress: -3) == 0)
        #expect(SegmentCard.syntheticKaraokeIndex(cumulativeChars: counts, progress: 9) == 2)
    }

    @Test("the rendered line keeps the words spaced with no trailing space")
    func syntheticTextJoinsWords() {
        let attr = SegmentCard.syntheticKaraokeText(tokens: ["uno", "due", "tre"], spokenIndex: 1)
        #expect(String(attr.characters) == "uno due tre")
    }

    @Test("the spoken token takes the transcript face at emphasis")
    func syntheticSpokenTokenTakesTheEmphasisTier() {
        let attr = SegmentCard.syntheticKaraokeText(tokens: ["uno", "due", "tre"], spokenIndex: 1)
        let fonts = attr.runs.compactMap(\.font)
        #expect(fonts == [DS.Font.transcriptEmphasis(serif: false)])
    }

    @Test("exactly one token carries the highlight")
    func syntheticTextHighlightsOneToken() {
        let attr = SegmentCard.syntheticKaraokeText(tokens: ["uno", "due", "tre"], spokenIndex: 1)
        let colored = attr.runs.filter { $0.foregroundColor != nil }
        #expect(colored.count == 1)
        #expect(colored.first.map { String(attr[$0.range].characters) } == "due ")
    }
}
