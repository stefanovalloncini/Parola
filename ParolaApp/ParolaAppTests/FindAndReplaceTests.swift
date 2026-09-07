import Foundation
import Testing
import ParolaCore
@testable import Parola
import ParolaTestSupport

private struct ImmediateClock: Clock {
    typealias Instant = ContinuousClock.Instant
    var now: Instant { ContinuousClock().now }
    var minimumResolution: Duration { .zero }
    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()
        await Task.yield()
    }
}

@MainActor
@Suite("AppModel find & replace")
struct FindAndReplaceTests {
    let model: AppModel

    init() {
        model = AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("findreplace"))
        model.transcript = Self.makeTranscript()
    }

    static func makeTranscript(
        _ texts: [String] = ["Hello world.", "Hello again, world.", "Goodbye WORLD!"]
    ) -> Transcript {
        let segments = texts.enumerated().map { idx, text in
            TranscriptSegment(
                id: idx,
                start: Double(idx),
                end: Double(idx) + 1,
                text: text
            )
        }
        return Transcript(segments: segments, language: "en", modelName: "tiny")
    }

    private func openFind(query: String, caseSensitive: Bool = false) {
        model.findIsOpen = true
        model.findCaseSensitive = caseSensitive
        model.findQuery = query
        model.recomputeMatches()
    }

    @Test("matches array reflects every occurrence with their segment IDs")
    func matchComputation() {
        openFind(query: "Hello")

        #expect(model.matches.count == 2)
        #expect(model.matches.map(\.segmentID) == [0, 1])
    }

    @Test("matches stay empty until find is opened")
    func matchesIgnoredWhenFindClosed() {
        model.findQuery = "world"
        model.recomputeMatches()

        #expect(model.findIsOpen == false)
        #expect(model.matches.isEmpty)
    }

    @Test("editing the transcript recomputes matches")
    func transcriptChangeInvalidatesMatches() throws {
        openFind(query: "Hello")
        try #require(model.matches.count == 2)

        model.editSegment(id: 0, newText: "Howdy world.")
        model.recomputeMatches()

        #expect(model.matches.count == 1)
        #expect(model.matches.first?.segmentID == 1)
    }

    @Test("goToNextMatch advances and wraps")
    func nextMatchWraps() throws {
        openFind(query: "Hello")
        try #require(model.matches.count == 2)

        model.currentMatchIndex = 0
        model.goToNextMatch()
        #expect(model.currentMatchIndex == 1)
        model.goToNextMatch()
        #expect(model.currentMatchIndex == 0)
    }

    @Test("goToPreviousMatch steps back and wraps")
    func previousMatchWraps() throws {
        openFind(query: "Hello")
        try #require(model.matches.count == 2)

        model.currentMatchIndex = 0
        model.goToPreviousMatch()
        #expect(model.currentMatchIndex == 1)
        model.goToPreviousMatch()
        #expect(model.currentMatchIndex == 0)
    }

    @Test("navigation is a no-op when matches is empty")
    func navigationWithoutMatches() throws {
        openFind(query: "no-such-word")
        try #require(model.matches.isEmpty)

        model.currentMatchIndex = 0
        model.goToNextMatch()
        model.goToPreviousMatch()
        #expect(model.currentMatchIndex == 0)
    }

    @Test("replaceAllMatches rewrites every occurrence and clears matches")
    func replaceAll() throws {
        openFind(query: "world")
        model.findReplacement = "earth"
        try #require(model.matches.count == 3)

        model.replaceAllMatches()

        let texts = model.transcript?.segments.map(\.text) ?? []
        #expect(texts == ["Hello earth.", "Hello again, earth.", "Goodbye earth!"])
        #expect(model.matches.isEmpty)
    }

    @Test("replaceCurrentMatch updates only the active segment")
    func replaceCurrent() throws {
        openFind(query: "Hello")
        model.findReplacement = "Hi"
        model.currentMatchIndex = 0
        try #require(model.matches.count == 2)

        model.replaceCurrentMatch()

        #expect(model.transcript?.segments[0].text == "Hi world.")
        #expect(model.transcript?.segments[1].text == "Hello again, world.")
        #expect(model.matches.count == 1)
    }

    @Test("case-insensitive search catches more than case-sensitive")
    func caseSensitivity() {
        openFind(query: "world", caseSensitive: false)
        #expect(model.matches.count == 3)

        openFind(query: "world", caseSensitive: true)
        #expect(model.matches.count == 2)
    }

    @Test("toggleFind clears state on close")
    func toggleFindClearsState() throws {
        openFind(query: "world")
        try #require(model.matches.isEmpty == false)

        model.toggleFind()

        #expect(model.findIsOpen == false)
        #expect(model.findQuery == "")
        #expect(model.matches.isEmpty)
        #expect(model.currentMatchIndex == 0)
    }

    @Test("match(in:) groups matches by segment")
    func matchesPerSegment() {
        model.transcript = Self.makeTranscript(["abc abc", "abc"])
        openFind(query: "abc")

        #expect(model.match(in: 0).count == 2)
        #expect(model.match(in: 1).count == 1)
        #expect(model.match(in: 99).isEmpty)
    }

    // MARK: - findWord

    private func makeDebouncedModel() -> AppModel {
        let bootstrap = AppBootstrap(
            mode: .test,
            library: makeTempLibraryURL("findword"),
            defaultsOverride: temporaryDefaults(),
            sideEffects: [],
            filePicker: TestFilePicker(),
            clock: ImmediateClock()
        )
        let model = AppModel(bootstrap: bootstrap)
        model.transcript = Self.makeTranscript()
        return model
    }

    private func waitForMatches(_ model: AppModel, on segmentIDs: [Int]) async -> Bool {
        for _ in 0..<200 {
            if model.matches.map(\.segmentID) == segmentIDs { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    @Test("findWord opens Find and lands on the word's matches")
    func findWordOpensWithMatches() async {
        let model = makeDebouncedModel()

        model.findWord("world")

        #expect(model.findIsOpen)
        #expect(model.findQuery == "world")
        #expect(await waitForMatches(model, on: [0, 1, 2]))
    }

    @Test("findWord replaces the query while Find is already open")
    func findWordReplacesOpenQuery() async {
        let model = makeDebouncedModel()
        model.findWord("Hello")
        _ = await waitForMatches(model, on: [0, 1])

        model.findWord("Goodbye")

        #expect(model.findQuery == "Goodbye")
        #expect(await waitForMatches(model, on: [2]))
    }

    @Test("opening a search result opens Find on the query it matched")
    func revealOpensFindOnABodyHit() {
        model.revealInTranscript("world")
        #expect(model.findIsOpen)
        #expect(model.findQuery == "world")
    }

    /// An entry can match on its title, summary or speaker names, none of which the transcript body holds.
    @Test("a match the transcript body does not hold leaves Find closed")
    func revealSkipsWhenTheBodyHasNoHit() {
        model.revealInTranscript("ornitorinco")
        #expect(!model.findIsOpen)
        #expect(model.findQuery.isEmpty)
    }

    @Test("opening a result with no transcript loaded leaves Find closed")
    func revealSkipsWithoutATranscript() {
        model.transcript = nil
        model.revealInTranscript("world", at: .init(seconds: 2, segmentIndex: 2, textOffset: 30))
        #expect(!model.findIsOpen)
        #expect(model.currentSegmentID == nil)
    }

    @Test("a result with a known position selects that segment")
    func revealSelectsTheHitsSegment() {
        model.revealInTranscript("world", at: .init(seconds: 2, segmentIndex: 2, textOffset: 30))
        #expect(model.currentSegmentID == 2)
        #expect(model.findIsOpen)
        #expect(model.findQuery == "world")
    }

    /// The index matches without regard to case, so its position stands where Find would show nothing.
    @Test("a case-sensitive Find selects the segment and stays closed")
    func revealSelectsTheSegmentUnderCaseSensitiveFind() {
        model.findCaseSensitive = true
        model.revealInTranscript("hello", at: .init(seconds: 1, segmentIndex: 1, textOffset: 12))
        #expect(model.currentSegmentID == 1)
        #expect(!model.findIsOpen)
        #expect(model.findQuery.isEmpty)
    }

    /// The index matches a query's tokens one by one, so "Hello world" is a hit no segment contains verbatim.
    @Test("a query no segment holds verbatim still jumps, without opening Find")
    func revealJumpsOnAMultiWordQueryWithoutOpeningFind() {
        model.revealInTranscript("Goodbye Hello", at: .init(seconds: 1, segmentIndex: 1, textOffset: 12))
        #expect(model.currentSegmentID == 1)
        #expect(!model.findIsOpen)
        #expect(model.findQuery.isEmpty)
    }

    @Test("a case-sensitive Find is not opened on a hit it would not find")
    func revealHonoursCaseSensitivity() {
        model.findCaseSensitive = true
        model.revealInTranscript("hello")
        #expect(!model.findIsOpen)
        #expect(model.currentSegmentID == nil)
    }

    /// The write lands before the route builds the transcript view, so the jump has to outlive it.
    @Test("a reveal with Find closed leaves the hit's segment pending for the transcript view")
    func revealLeavesAPendingRequest() {
        model.revealInTranscript("Goodbye Hello", at: .init(seconds: 1, segmentIndex: 1, textOffset: 12))
        #expect(!model.findIsOpen)
        #expect(model.currentSegmentID == 1)
        #expect(model.pendingRevealSegmentID == 1)
    }

    /// `installPlayer`'s first delivery lands after the reveal and covers t = 0.
    @Test("a paused player's ticks leave a revealed segment where it is")
    func revealSurvivesThePlayersTicks() {
        model.revealInTranscript("Goodbye Hello", at: .init(seconds: 1, segmentIndex: 1, textOffset: 12))
        model.updateCurrentSegment(time: 0)
        model.updateCurrentSegment(time: 0)
        #expect(model.currentSegmentID == 1)

        model.pendingRevealSegmentID = nil
        model.updateCurrentSegment(time: 0)
        #expect(model.currentSegmentID == 0)
    }

    /// The scrubber, the restart seek and skip all land on `seekPlayer`, and none of them presses play.
    @Test("a seek takes the selection back from a reveal")
    func aSeekEndsTheReveal() {
        model.revealInTranscript("Goodbye Hello", at: .init(seconds: 1, segmentIndex: 1, textOffset: 12))
        #expect(model.currentSegmentID == 1)

        model.seekPlayer(to: 2.5)

        #expect(model.pendingRevealSegmentID == nil)
        #expect(model.currentSegmentID == 2)
    }

    /// A summary run and the YouTube-subtitles path swap the transcript without touching the player.
    @Test("installing another stored transcript drops the reveal")
    func aTranscriptSwapEndsTheReveal() {
        model.revealInTranscript("Goodbye Hello", at: .init(seconds: 1, segmentIndex: 1, textOffset: 12))
        model.installStoredTranscript(Self.makeTranscript())
        #expect(model.pendingRevealSegmentID == nil)
    }

    /// Every entry the app opens installs or tears down a player before the reveal runs.
    @Test("opening another entry drops the reveal the last one carried")
    func revealDoesNotOutliveItsEntry() {
        model.revealInTranscript("Goodbye Hello", at: .init(seconds: 1, segmentIndex: 1, textOffset: 12))
        model.tearDownPlayer()
        #expect(model.pendingRevealSegmentID == nil)
    }

    /// The media's real length is backfilled into the transcript a moment after the entry opens.
    @Test("a duration backfill does not cancel the reveal")
    func revealSurvivesATranscriptPatch() {
        model.revealInTranscript("Goodbye Hello", at: .init(seconds: 1, segmentIndex: 1, textOffset: 12))
        var patched = model.transcript
        patched?.durationSeconds = 42
        model.transcript = patched
        #expect(model.pendingRevealSegmentID == 1)
    }

    /// The index counts segments the app never sees, so the time beside the hit decides which line it is.
    @Test("a stale segment index loses to the hit's time")
    func revealResolvesAStaleIndexByTime() {
        model.revealInTranscript("world", at: .init(seconds: 2, segmentIndex: 0, textOffset: 0))
        #expect(model.currentSegmentID == 2)
        #expect(model.pendingRevealSegmentID == 2)
    }

    /// A position from an index that no longer matches the transcript must not select a segment at random.
    @Test("a position past the end of the transcript falls back to the body")
    func revealIgnoresAStalePosition() {
        model.revealInTranscript("ornitorinco", at: .init(seconds: 9, segmentIndex: 99, textOffset: 900))
        #expect(!model.findIsOpen)
        #expect(model.currentSegmentID == nil)
        model.revealInTranscript("world", at: .init(seconds: 9, segmentIndex: 99, textOffset: 900))
        #expect(model.findIsOpen)
    }

    /// This phrase exists in `transcript.text`'s joined form but not inside either segment alone.
    @Test("a query straddling a segment boundary leaves Find closed")
    func revealSkipsAQueryStraddlingASegmentBoundary() {
        model.revealInTranscript("world. Hello")
        #expect(!model.findIsOpen)
        #expect(model.findQuery.isEmpty)
    }

    /// `transcriptHasMatch` stops at the first hit instead of collecting every one like `findMatches`; the two must still agree on emptiness.
    @Test("the match probe agrees with a full scan's emptiness")
    func matchProbeAgreesWithFindMatches() {
        let transcript = Self.makeTranscript()
        for (query, caseSensitive) in [
            ("Hello", false), ("hello", true), ("ornitorinco", false), ("world. Hello", false), ("WORLD", false),
        ] {
            let expected = !transcript.findMatches(query, caseSensitive: caseSensitive).isEmpty
            #expect(
                AppModel.transcriptHasMatch(query, caseSensitive: caseSensitive, in: transcript.segments) == expected,
                "mismatch for \"\(query)\" caseSensitive=\(caseSensitive)"
            )
        }
        #expect(AppModel.transcriptHasMatch("", caseSensitive: false, in: transcript.segments) == false)
    }
}
