import Foundation
import Testing
@testable import ParolaCore

@Suite("Word frequency")
struct WordFrequencyTests {
    @Test("counts case-insensitively")
    func countsCaseInsensitive() {
        let freq = WordFrequency.compute(text: "Apple apple APPLE banana", limit: 5)
        let apples = freq.first { $0.word == "apple" }?.count ?? 0
        #expect(apples == 3)
    }

    @Test("strips punctuation around tokens")
    func stripsPunctuation() {
        let freq = WordFrequency.compute(text: "Hello, world! World? hello.", limit: 5)
        let hello = freq.first { $0.word == "hello" }?.count ?? 0
        #expect(hello == 2)
    }

    @Test("skips common stop words")
    func skipsStopWords() {
        let freq = WordFrequency.compute(text: "the cat sat on the mat", limit: 5)
        let words = freq.map(\.word)
        #expect(words.contains("the") == false)
        #expect(words.contains("on") == false)
        #expect(words.contains("cat"))
    }

    @Test("respects the limit")
    func respectsLimit() {
        let text = (1...20).map { "word\($0)" }.joined(separator: " ")
        let freq = WordFrequency.compute(text: text, limit: 5)
        #expect(freq.count == 5)
    }

    @Test("ignores tokens shorter than the minimum length")
    func minLength() {
        let freq = WordFrequency.compute(text: "a cat sat in a fox box", limit: 10, minLength: 3)
        let words = freq.map(\.word)
        #expect(words.contains("a") == false)
        #expect(words.contains("in") == false)
    }

    @Test("ranks by count descending")
    func ranksByCount() {
        let freq = WordFrequency.compute(text: "alpha beta alpha gamma alpha beta", limit: 5)
        #expect(freq.first?.word == "alpha")
        #expect(freq.first?.count == 3)
    }

    @Test("empty input yields empty list")
    func emptyInput() {
        #expect(WordFrequency.compute(text: "", limit: 5).isEmpty)
        #expect(WordFrequency.compute(text: "the of and", limit: 5).isEmpty)
    }
}
