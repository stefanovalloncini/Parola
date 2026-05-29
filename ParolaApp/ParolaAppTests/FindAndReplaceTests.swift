import Foundation
import Testing
import ParolaCore
@testable import Parola

@MainActor
@Suite("AppModel find & replace")
struct FindAndReplaceTests {
    let model: AppModel

    init() {
        model = AppModel(skipBootstrap: true, defaults: UserDefaults(suiteName: "test-\(UUID())")!)
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
}
