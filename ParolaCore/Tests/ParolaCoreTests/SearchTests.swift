import Foundation
import Testing
@testable import ParolaCore

@Suite("Find & replace")
struct SearchTests {
    private func sample() -> Transcript {
        Transcript(
            segments: [
                TranscriptSegment(id: 0, start: 0, end: 1, text: "Hello world."),
                TranscriptSegment(id: 1, start: 1, end: 2, text: "Hello again, world."),
                TranscriptSegment(id: 2, start: 2, end: 3, text: "Goodbye world!"),
            ],
            language: "en",
            modelName: "tiny"
        )
    }

    @Test("empty query returns no matches")
    func emptyQuery() {
        #expect(sample().findMatches("").isEmpty)
    }

    @Test("case-insensitive find returns every occurrence")
    func findAll() {
        let matches = sample().findMatches("hello")
        #expect(matches.count == 2)
        #expect(matches[0].segmentID == 0)
        #expect(matches[1].segmentID == 1)
    }

    @Test("case-sensitive find respects case")
    func caseSensitive() {
        #expect(sample().findMatches("hello", caseSensitive: true).isEmpty)
        #expect(sample().findMatches("Hello", caseSensitive: true).count == 2)
    }

    @Test("multiple matches in one segment")
    func multipleInOne() {
        let t = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "abcabcabc")],
            language: "en",
            modelName: "tiny"
        )
        let matches = t.findMatches("abc")
        #expect(matches.count == 3)
        #expect(matches.map(\.range.lowerBound) == [0, 3, 6])
    }

    @Test("replace single match leaves other segments alone")
    func replaceSingle() {
        let matches = sample().findMatches("Hello")
        let updated = sample().applying(replacement: "Hi", to: matches[0])
        #expect(updated.segments[0].text == "Hi world.")
        #expect(updated.segments[1].text == "Hello again, world.")
        #expect(updated.segments[2].text == "Goodbye world!")
    }

    @Test("replaceAll hits every occurrence")
    func replaceAll() {
        let updated = sample().replacingAll("world", with: "earth")
        #expect(updated.segments[0].text == "Hello earth.")
        #expect(updated.segments[1].text == "Hello again, earth.")
        #expect(updated.segments[2].text == "Goodbye earth!")
    }

    @Test("replaceAll with empty query is a no-op")
    func replaceAllEmpty() {
        let t = sample()
        #expect(t.replacingAll("", with: "x").segments.map(\.text) == t.segments.map(\.text))
    }

    @Test("replace with a negative-offset match range leaves the text unchanged")
    func replaceNegativeRange() {
        let t = sample()
        let updated = t.applying(replacement: "X", to: TranscriptMatch(segmentID: 0, range: -1..<2))
        #expect(updated.segments[0].text == "Hello world.")
    }

    @Test("works with accented characters")
    func unicode() {
        let t = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "Caffè caffè CAFFÈ")],
            language: "it",
            modelName: "tiny"
        )
        #expect(t.findMatches("caffè").count == 3)
        #expect(t.findMatches("caffè", caseSensitive: true).count == 1)
    }
}
