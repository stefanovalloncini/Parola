import Foundation
import Testing
@testable import Parola
import ParolaCore

@Suite("Word chip elision merge")
struct WordMergeTests {
    private func word(_ id: String, _ text: String, start: Double = 0, end: Double = 1) -> WordTiming {
        WordTiming(id: id, word: text, start: start, end: end, probability: 1)
    }

    @Test("a straight-apostrophe tail folds onto the previous word")
    func mergesStraightApostrophe() {
        let merged = WordsView.mergeElidedWords([
            word("0:0", "l", start: 1.0),
            word("0:1", "'altro", start: 1.4),
        ])
        #expect(merged.count == 1)
        #expect(merged.first?.text == "l'altro")
        #expect(merged.first?.start == 1.0)
        #expect(merged.first?.wordIDs == ["0:0", "0:1"])
    }

    @Test("a curly-apostrophe tail folds onto the previous word")
    func mergesCurlyApostrophe() {
        let merged = WordsView.mergeElidedWords([
            word("0:0", "c"),
            word("0:1", "\u{2019}è"),
        ])
        #expect(merged.count == 1)
        #expect(merged.first?.text == "c\u{2019}è")
    }

    @Test("distinct words stay as separate chips")
    func keepsDistinctWordsSeparate() {
        let merged = WordsView.mergeElidedWords([
            word("0:0", "ciao"),
            word("0:1", "mondo"),
        ])
        #expect(merged.map(\.text) == ["ciao", "mondo"])
        #expect(merged.map(\.wordIDs) == [["0:0"], ["0:1"]])
    }

    @Test("a leading-apostrophe first token starts its own chip")
    func leadingApostropheFirstTokenStandsAlone() {
        let merged = WordsView.mergeElidedWords([word("0:0", "'altro")])
        #expect(merged.count == 1)
        #expect(merged.first?.text == "'altro")
    }

    @Test("the merged chip carries every constituent word id for highlighting")
    func mergedChipTracksAllConstituents() {
        let merged = WordsView.mergeElidedWords([
            word("0:0", "dell"),
            word("0:1", "'anno"),
        ])
        #expect(merged.first?.wordIDs.contains("0:1") == true)
    }
}
