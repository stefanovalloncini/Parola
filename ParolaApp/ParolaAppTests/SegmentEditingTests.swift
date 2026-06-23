import Foundation
import Testing
import ParolaCore
@testable import Parola

@MainActor
@Suite("AppModel segment editing")
struct SegmentEditingTests {
    let model: AppModel

    init() {
        model = AppModel(skipBootstrap: true, defaults: UserDefaults(suiteName: "test-\(UUID())")!, libraryURL: makeTempLibraryURL("segmentedit"))
        model.transcript = Self.makeTranscript()
    }

    static func makeTranscript(
        _ texts: [String] = ["Hello world.", "Second segment."]
    ) -> Transcript {
        let segments = texts.enumerated().map { idx, text in
            TranscriptSegment(id: idx, start: Double(idx), end: Double(idx) + 1, text: text)
        }
        return Transcript(segments: segments, language: "en", modelName: "tiny")
    }

    @Test("clearing a segment's text is rejected, keeping the segment intact")
    func emptyEditRejected() throws {
        model.editSegment(id: 0, newText: "")

        let segments = try #require(model.transcript?.segments)
        #expect(segments.count == 2)
        #expect(segments[0].text == "Hello world.")
    }

    @Test("a whitespace-only edit is rejected like an empty one")
    func whitespaceEditRejected() throws {
        model.editSegment(id: 0, newText: "  \n\t ")

        #expect(model.transcript?.segments[0].text == "Hello world.")
    }

    @Test("a normal edit trims surrounding whitespace before storing")
    func normalEditTrims() {
        model.editSegment(id: 0, newText: "  Howdy there.  ")

        #expect(model.transcript?.segments[0].text == "Howdy there.")
    }

    @Test("a normal non-empty edit replaces the text")
    func normalEditApplies() {
        model.editSegment(id: 1, newText: "Changed.")

        #expect(model.transcript?.segments[1].text == "Changed.")
    }

    @Test("editing a segment drops its now-stale word timings, leaving siblings intact")
    func editDropsStaleWordTimings() throws {
        let words = [
            WordTiming(id: "0-0", word: "Hello", start: 0, end: 0.5, probability: 1),
            WordTiming(id: "0-1", word: "world.", start: 0.5, end: 1, probability: 1),
        ]
        model.transcript = Transcript(
            segments: [
                TranscriptSegment(id: 0, start: 0, end: 1, text: "Hello world.", words: words),
                TranscriptSegment(id: 1, start: 1, end: 2, text: "Second segment.", words: words),
            ],
            language: "en",
            modelName: "tiny"
        )

        model.editSegment(id: 0, newText: "Howdy there.")

        let segments = try #require(model.transcript?.segments)
        #expect(segments[0].text == "Howdy there.")
        #expect(segments[0].words == nil)
        #expect(segments[1].words == words)
    }

    @Test("a rejected edit leaves the segment's word timings intact")
    func rejectedEditKeepsWordTimings() throws {
        let words = [WordTiming(id: "0-0", word: "Hello", start: 0, end: 1, probability: 1)]
        model.transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "Hello world.", words: words)],
            language: "en",
            modelName: "tiny"
        )

        model.editSegment(id: 0, newText: "  Hello world.  ")

        #expect(model.transcript?.segments[0].words == words)
    }
}
