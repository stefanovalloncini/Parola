import Testing
import Foundation
@testable import Parola
import ParolaCore

@Suite("TranscriptFind")
struct TranscriptFindTests {
    @Test("matches ignore case and skip empty queries")
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
}

@Suite("TranscriptFindState")
@MainActor
struct TranscriptFindStateTests {
    private func makeState() -> TranscriptFindState {
        let state = TranscriptFindState()
        state.debounce = .milliseconds(100)
        return state
    }

    @Test("the applied query, matches and position change together once the debounce fires")
    func appliesAfterDebounce() async {
        let state = makeState()
        let segments = Fixtures.makeLongTranscript(segments: 50, wordsPerSegment: 5).segments
        state.currentMatchIndex = 3
        let task = Task { await state.queryChanged("budget", in: segments) }
        #expect(state.appliedQuery.isEmpty)
        #expect(state.matchSet.isEmpty)
        #expect(state.currentMatchIndex == 3)
        await task.value
        #expect(state.appliedQuery == "budget")
        #expect(!state.matchSet.isEmpty)
        #expect(state.currentMatchIndex == 0)
    }

    @Test("a keystroke that supersedes the pending query leaves it unapplied")
    func supersededQueryNeverApplies() async {
        let state = makeState()
        let segments = Fixtures.makeLongTranscript(segments: 50, wordsPerSegment: 5).segments
        let first = Task { await state.queryChanged("bud", in: segments) }
        first.cancel()
        await first.value
        #expect(state.appliedQuery.isEmpty)
    }

    @Test("clearing the field applies at once")
    func clearApplies() async {
        let state = makeState()
        let segments = Fixtures.makeLongTranscript(segments: 50, wordsPerSegment: 5).segments
        await state.queryChanged("budget", in: segments)
        await state.queryChanged("  ", in: segments)
        #expect(state.appliedQuery.isEmpty)
        #expect(state.matchIDs.isEmpty)
    }

    @Test("advance wraps around the matches")
    func advanceWraps() async {
        let state = makeState()
        let segments = Fixtures.makeTranscript().segments
        await state.queryChanged("o", in: segments)
        #expect(state.matchIDs == [0, 1])
        state.advance()
        #expect(state.targetMatchID == 1)
        state.advance()
        #expect(state.targetMatchID == 0)
    }
}
