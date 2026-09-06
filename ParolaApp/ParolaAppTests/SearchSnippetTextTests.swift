import Foundation
import Testing
@testable import Parola
import ParolaCore

@Suite("Search snippet text")
struct SearchSnippetTextTests {
    private func match(_ snippet: String, _ highlights: [(Int, Int)]) -> LibrarySearchIndex.Match {
        LibrarySearchIndex.Match(
            entryID: "e",
            score: 1,
            snippet: snippet,
            highlights: highlights.map { LibrarySearchIndex.Highlight(start: $0.0, length: $0.1) }
        )
    }

    @Test("the marked ranges cover the terms the index found")
    func marksTheTerms() {
        let snippet = "il lancio della nuova versione"
        let ranges = SearchSnippetText.markedRanges(match(snippet, [(3, 6)]))
        #expect(ranges == [3..<9])
        let chars = Array(snippet)
        #expect(String(chars[3..<9]) == "lancio")
    }

    @Test("a highlight past the end of the snippet is dropped")
    func dropsOutOfRangeHighlights() {
        #expect(SearchSnippetText.markedRanges(match("breve", [(40, 3)])).isEmpty)
        #expect(SearchSnippetText.markedRanges(match("breve", [(2, 0)])).isEmpty)
    }

    @Test("a highlight running past the end stops at the end")
    func clampsToTheSnippet() {
        #expect(SearchSnippetText.markedRanges(match("breve", [(3, 20)])) == [3..<5])
    }

    @Test("accented text keeps character offsets, not byte offsets")
    func countsCharactersNotBytes() {
        let snippet = "però il lancio"
        let ranges = SearchSnippetText.markedRanges(match(snippet, [(8, 6)]))
        #expect(ranges == [8..<14])
        let chars = Array(snippet)
        #expect(String(chars[8..<14]) == "lancio")
    }

    @Test("out-of-order highlights come back sorted, so none are dropped as before the cursor")
    func sortsOutOfOrderHighlights() {
        let ranges = SearchSnippetText.markedRanges(match("il lancio e il lancio", [(15, 6), (3, 6)]))
        #expect(ranges == [3..<9, 15..<21])
    }

    @Test("every marked range survives the round trip into an attributed string")
    func attributedKeepsEveryRun() {
        let text = SearchSnippetText.attributed(match("il lancio e il lancio", [(3, 6), (15, 6)]))
        let marked = text.runs.filter { $0.foregroundColor != nil }.map { String(text[$0.range].characters) }
        #expect(marked == ["lancio", "lancio"])
    }

    @Test("an untinted hit keeps its weight and drops the accent")
    func untintedHitKeepsItsWeight() {
        let text = SearchSnippetText.attributed(match("il lancio", [(3, 6)]), tinted: false)
        #expect(text.runs.allSatisfy { $0.foregroundColor == nil })
        let bold = text.runs.filter { $0.font == DS.Font.captionEmphasized }.map { String(text[$0.range].characters) }
        #expect(bold == ["lancio"])
    }
}
