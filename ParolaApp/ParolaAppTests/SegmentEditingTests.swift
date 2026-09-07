import Foundation
import Testing
import ParolaCore
@testable import Parola
import ParolaTestSupport

@MainActor
@Suite("AppModel segment editing")
struct SegmentEditingTests {
    let model: AppModel

    init() {
        model = AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("segmentedit"))
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

    @Test("deleting a segment removes only it and keeps the others in order")
    func deleteRemovesTargetedSegment() throws {
        model.transcript = Self.makeTranscript(["First.", "Second.", "Third."])

        model.deleteSegment(id: 1)

        let segments = try #require(model.transcript?.segments)
        #expect(segments.map(\.id) == [0, 2])
        #expect(segments.map(\.text) == ["First.", "Third."])
    }

    @Test("deleting an unknown id leaves the transcript untouched")
    func deleteUnknownIdIsNoOp() {
        model.transcript = Self.makeTranscript(["First.", "Second."])
        let before = model.transcript

        model.deleteSegment(id: 99)

        #expect(model.transcript == before)
    }

    @Test("deleting a segment leaves a sibling's word timings intact")
    func deletePreservesSiblingWordTimings() throws {
        let words = [WordTiming(id: "1-0", word: "Second", start: 1, end: 2, probability: 1)]
        model.transcript = Transcript(
            segments: [
                TranscriptSegment(id: 0, start: 0, end: 1, text: "First."),
                TranscriptSegment(id: 1, start: 1, end: 2, text: "Second.", words: words),
            ],
            language: "en",
            modelName: "tiny"
        )

        model.deleteSegment(id: 0)

        let segments = try #require(model.transcript?.segments)
        #expect(segments.map(\.id) == [1])
        #expect(segments[0].words == words)
    }

    @Test("nudging a segment's start shifts it by frames over the subtitle fps, leaving the end put")
    func nudgeStartShiftsBoundaryViaSubtitleFps() throws {
        model.subtitleFPS = 30
        model.transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 1, end: 2, text: "Only.")],
            language: "en",
            modelName: "tiny"
        )

        model.nudgeSegmentStart(id: 0, frames: 3)

        let segment = try #require(model.transcript?.segments.first)
        #expect(abs(segment.start - 1.1) < 1e-9)
        #expect(segment.end == 2)
    }

    @Test("nudging a segment's end shifts it by frames over the subtitle fps, leaving the start put")
    func nudgeEndShiftsBoundaryViaSubtitleFps() throws {
        model.subtitleFPS = 30
        model.transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 1, end: 2, text: "Only.")],
            language: "en",
            modelName: "tiny"
        )

        model.nudgeSegmentEnd(id: 0, frames: -3)

        let segment = try #require(model.transcript?.segments.first)
        #expect(segment.start == 1)
        #expect(abs(segment.end - 1.9) < 1e-9)
    }

    @Test("nudging with no transcript loaded is a graceful no-op")
    func nudgeWithoutTranscriptIsNoOp() {
        model.transcript = nil

        model.nudgeSegmentStart(id: 0, frames: 5)
        model.nudgeSegmentEnd(id: 0, frames: 5)

        #expect(model.transcript == nil)
    }

    @Test("nudging a segment boundary keeps its word timings (unlike a text edit)")
    func nudgeKeepsWordTimings() throws {
        let words = [WordTiming(id: "0-0", word: "Only.", start: 1, end: 2, probability: 1)]
        model.subtitleFPS = 30
        model.transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 1, end: 2, text: "Only.", words: words)],
            language: "en",
            modelName: "tiny"
        )

        model.nudgeSegmentEnd(id: 0, frames: -3)

        #expect(model.transcript?.segments[0].words == words)
    }
}
