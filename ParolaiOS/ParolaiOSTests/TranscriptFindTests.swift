import Testing
import Foundation
@testable import Parola
import ParolaCore

@Suite("TranscriptFind")
struct TranscriptFindTests {
    @Test("matches ignore case and diacritic-free letters, and skip empty queries")
    func matching() {
        let segments = Fixtures.makeTranscript().segments
        #expect(TranscriptFind.matchingIDs(in: segments, query: "WORLD") == [0])
        #expect(TranscriptFind.matchingIDs(in: segments, query: "o") == [0, 1])
        #expect(TranscriptFind.matchingIDs(in: segments, query: "").isEmpty)
        #expect(TranscriptFind.matchingIDs(in: segments, query: "zzz").isEmpty)
    }

    @Test("the NSString scan finds what the String scan finds on a long transcript")
    func agreesWithStringScan() {
        let segments = Fixtures.makeLongTranscript().segments
        for query in ["budget", "PAROLA", "l'altro", "lunedì", "a b"] {
            let expected = segments.filter { $0.text.range(of: query, options: .caseInsensitive) != nil }.map(\.id)
            #expect(TranscriptFind.matchingIDs(in: segments, query: query) == expected)
        }
    }

    @Test("debounce is 150 ms")
    func debounce() {
        #expect(TranscriptFind.debounce == .milliseconds(150))
    }
}
