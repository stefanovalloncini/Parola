import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Segment split and merge")
struct SplitMergeSegmentTests {
    let model: AppModel
    let undo = UndoManager()

    init() {
        model = AppModel(
            skipBootstrap: true,
            defaults: temporaryDefaults(),
            libraryURL: makeTempLibraryURL("splitmerge")
        )
        undo.groupsByEvent = false
        model.undoManager = undo
    }

    static func wordedTranscript() -> Transcript {
        let words = [
            WordTiming(id: "0-0", word: "Uno", start: 0.0, end: 0.9, probability: 1),
            WordTiming(id: "0-1", word: "due", start: 1.0, end: 1.9, probability: 1),
            WordTiming(id: "0-2", word: "tre", start: 2.0, end: 2.9, probability: 1),
            WordTiming(id: "0-3", word: "quattro", start: 3.0, end: 4.0, probability: 1),
        ]
        return Transcript(
            segments: [
                TranscriptSegment(id: 0, start: 0, end: 4, text: "Uno due tre quattro", speaker: "Speaker 1", words: words),
                TranscriptSegment(id: 1, start: 4, end: 6, text: "Coda finale.", speaker: "Speaker 2"),
            ],
            language: "it",
            modelName: "stub"
        )
    }

    static func plainTranscript() -> Transcript {
        Transcript(
            segments: [
                TranscriptSegment(id: 0, start: 0, end: 16, text: "Alpha beta gamma", speaker: "Speaker 1"),
                TranscriptSegment(id: 1, start: 16, end: 20, text: "Delta."),
            ],
            language: "en",
            modelName: "stub"
        )
    }

    // MARK: - Split with word timings

    @Test("split hands back the ids it minted")
    func splitReturnsTheNewIDs() throws {
        let segments = Self.wordedTranscript().segments
        let byWord = try #require(SegmentSurgery.split(segments: segments, id: 0, atWordIndex: 2))
        #expect(byWord.firstID == 2 && byWord.secondID == 3)
        #expect(byWord.segments.map(\.id) == [byWord.firstID, byWord.secondID, 1])

        let byFraction = try #require(
            SegmentSurgery.split(segments: Self.plainTranscript().segments, id: 0, atFraction: 0.5)
        )
        #expect(byFraction.firstID == 2 && byFraction.secondID == 3)
        #expect(byFraction.segments.map(\.id) == [byFraction.firstID, byFraction.secondID, 1])
    }

    @Test("split at a word boundary distributes words, times, and text")
    func splitAtWordBoundary() throws {
        model.transcript = Self.wordedTranscript()
        model.splitSegment(id: 0, atWordIndex: 2)

        let segments = try #require(model.transcript?.segments)
        #expect(segments.count == 3)
        #expect(segments.map(\.id) == [2, 3, 1])

        #expect(segments[0].text == "Uno due")
        #expect(segments[0].start == 0)
        #expect(segments[0].end == 2.0)
        #expect(segments[0].speaker == "Speaker 1")
        #expect(segments[0].words?.map(\.word) == ["Uno", "due"])
        #expect(segments[0].words?.map(\.id) == ["2-0", "2-1"])

        #expect(segments[1].text == "tre quattro")
        #expect(segments[1].start == 2.0)
        #expect(segments[1].end == 4.0)
        #expect(segments[1].speaker == "Speaker 1")
        #expect(segments[1].words?.map(\.word) == ["tre", "quattro"])
        #expect(segments[1].words?.map(\.id) == ["3-0", "3-1"])
    }

    @Test("split at word index 0 or past the end is a no-op")
    func splitAtDegenerateWordIndexNoOps() {
        model.transcript = Self.wordedTranscript()
        model.splitSegment(id: 0, atWordIndex: 0)
        model.splitSegment(id: 0, atWordIndex: 4)
        model.splitSegment(id: 0, atWordIndex: -1)
        model.splitSegment(id: 99, atWordIndex: 2)

        #expect(model.transcript == Self.wordedTranscript())
        #expect(!undo.canUndo)
    }

    @Test("repeated splits keep segment ids unique")
    func repeatedSplitsKeepIDsUnique() throws {
        model.transcript = Self.wordedTranscript()
        model.splitSegment(id: 0, atWordIndex: 2)
        let firstHalfID = try #require(model.transcript?.segments.first?.id)
        model.splitSegment(id: firstHalfID, atWordIndex: 1)

        let segments = try #require(model.transcript?.segments)
        #expect(segments.count == 4)
        #expect(Set(segments.map(\.id)).count == segments.count)
        #expect(segments == segments.sorted { $0.start < $1.start })
    }

    // MARK: - Split without word timings

    @Test("split at a fraction cuts at the nearest whitespace with interpolated times")
    func splitAtFractionWithoutWords() throws {
        model.transcript = Self.plainTranscript()
        model.splitSegment(id: 0, atFraction: 0.5)

        let segments = try #require(model.transcript?.segments)
        #expect(segments.count == 3)
        #expect(segments.map(\.id) == [2, 3, 1])
        #expect(segments[0].text == "Alpha beta")
        #expect(segments[1].text == "gamma")
        // "Alpha beta gamma" is 16 chars; the whitespace at offset 10 is nearest 0.5*16 = 8.
        #expect(segments[0].start == 0)
        #expect(abs(segments[0].end - 10.0) < 0.0001)
        #expect(segments[1].start == segments[0].end)
        #expect(segments[1].end == 16)
        #expect(segments[0].words == nil)
        #expect(segments[1].words == nil)
        #expect(segments[0].speaker == "Speaker 1")
        #expect(segments[1].speaker == "Speaker 1")
    }

    @Test("split at a fraction with word timings snaps to the nearest word boundary")
    func splitAtFractionSnapsToWords() throws {
        model.transcript = Self.wordedTranscript()
        model.splitSegment(id: 0, atFraction: 0.5)

        let segments = try #require(model.transcript?.segments)
        #expect(segments.count == 3)
        #expect(segments[0].text == "Uno due")
        #expect(segments[1].text == "tre quattro")
        #expect(segments[0].end == 2.0)
    }

    @Test("splitting a segment without whitespace is a no-op")
    func splitWithoutWhitespaceNoOps() {
        model.transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 2, text: "Ciao")],
            language: "it",
            modelName: "stub"
        )
        model.splitSegment(id: 0, atFraction: 0.5)

        #expect(model.transcript?.segments.count == 1)
        #expect(!undo.canUndo)
    }

    // MARK: - Merge

    @Test("merge concatenates text, spans times, and keeps the first id and speaker")
    func mergeSpansAndKeepsFirstIdentity() throws {
        model.transcript = Self.wordedTranscript()
        model.mergeSegmentWithNext(id: 0)

        let segments = try #require(model.transcript?.segments)
        #expect(segments.count == 1)
        #expect(segments[0].id == 0)
        #expect(segments[0].start == 0)
        #expect(segments[0].end == 6)
        #expect(segments[0].text == "Uno due tre quattro Coda finale.")
        #expect(segments[0].speaker == "Speaker 1")
    }

    @Test("merge drops words when either side has none")
    func mergeNilsWordsWhenOneSideMissing() throws {
        model.transcript = Self.wordedTranscript()
        model.mergeSegmentWithNext(id: 0)

        #expect(try #require(model.transcript?.segments)[0].words == nil)
    }

    @Test("merge concatenates and re-ids words when both sides have them")
    func mergeConcatenatesWords() throws {
        var t = Self.wordedTranscript()
        t.segments[1].words = [
            WordTiming(id: "1-0", word: "Coda", start: 4.0, end: 4.9, probability: 1),
            WordTiming(id: "1-1", word: "finale.", start: 5.0, end: 6.0, probability: 1),
        ]
        model.transcript = t
        model.mergeSegmentWithNext(id: 0)

        let merged = try #require(model.transcript?.segments.first)
        #expect(merged.words?.map(\.word) == ["Uno", "due", "tre", "quattro", "Coda", "finale."])
        #expect(merged.words?.map(\.id) == ["0-0", "0-1", "0-2", "0-3", "0-4", "0-5"])
    }

    @Test("merging the last segment or a missing id is a no-op")
    func mergeDegenerateCasesNoOp() {
        model.transcript = Self.wordedTranscript()
        model.mergeSegmentWithNext(id: 1)
        model.mergeSegmentWithNext(id: 99)

        #expect(model.transcript == Self.wordedTranscript())
        #expect(!undo.canUndo)
    }

    // MARK: - Undo integration

    @Test("split round-trips through undo and redo")
    func splitUndoRedoRoundTrip() throws {
        let original = Self.wordedTranscript()
        model.transcript = original
        model.splitSegment(id: 0, atWordIndex: 2)
        #expect(undo.undoActionName == "Split Segment")

        undo.undo()
        #expect(model.transcript == original)

        undo.redo()
        #expect(model.transcript?.segments.count == 3)
    }

    @Test("merge round-trips through undo, restoring the second speaker")
    func mergeUndoRoundTrip() throws {
        let original = Self.wordedTranscript()
        model.transcript = original
        model.mergeSegmentWithNext(id: 0)
        #expect(undo.undoActionName == "Merge Segments")

        undo.undo()
        #expect(model.transcript == original)
        #expect(model.transcript?.segments[1].speaker == "Speaker 2")
    }
}
