import Foundation
import Testing
import ParolaCore

@Suite("Segment split and merge transforms")
struct SegmentSurgeryTests {
    private static func words(_ tokens: [String], segmentID: Int, start: Double = 0) -> [WordTiming] {
        tokens.enumerated().map { index, token in
            WordTiming(
                id: "\(segmentID)-\(index)",
                word: token,
                start: start + Double(index),
                end: start + Double(index) + 0.9,
                probability: 1
            )
        }
    }

    private static let worded: [TranscriptSegment] = [
        TranscriptSegment(
            id: 0, start: 0, end: 4, text: "Uno due tre quattro", speaker: "Speaker 1",
            words: words(["Uno", "due", "tre", "quattro"], segmentID: 0)
        ),
        TranscriptSegment(id: 1, start: 4, end: 6, text: "Coda finale.", speaker: "Speaker 2"),
    ]

    private static let plain: [TranscriptSegment] = [
        TranscriptSegment(id: 0, start: 0, end: 16, text: "Alpha beta gamma", speaker: "Speaker 1"),
        TranscriptSegment(id: 1, start: 16, end: 20, text: "Delta."),
    ]

    @Test("split hands back the ids it minted")
    func splitReturnsTheNewIDs() throws {
        let byWord = try #require(SegmentSurgery.split(segments: Self.worded, id: 0, atWordIndex: 2))
        #expect(byWord.firstID == 2 && byWord.secondID == 3)
        #expect(byWord.segments.map(\.id) == [byWord.firstID, byWord.secondID, 1])

        let byFraction = try #require(SegmentSurgery.split(segments: Self.plain, id: 0, atFraction: 0.5))
        #expect(byFraction.firstID == 2 && byFraction.secondID == 3)
        #expect(byFraction.segments.map(\.id) == [byFraction.firstID, byFraction.secondID, 1])
    }

    @Test("split at a word index carries words, times, text and speaker into both halves")
    func splitAtWordIndex() throws {
        let split = try #require(SegmentSurgery.split(segments: Self.worded, id: 0, atWordIndex: 2))
        let first = split.segments[0]
        let second = split.segments[1]

        #expect(first.text == "Uno due")
        #expect(first.start == 0 && first.end == 2)
        #expect(first.words?.map(\.id) == ["2-0", "2-1"])
        #expect(second.text == "tre quattro")
        #expect(second.start == 2 && second.end == 4)
        #expect(second.words?.map(\.id) == ["3-0", "3-1"])
        #expect(first.speaker == "Speaker 1" && second.speaker == "Speaker 1")
    }

    @Test("split at an out-of-range word index or an unknown id returns nil", arguments: [0, 4, -1])
    func splitAtDegenerateWordIndex(index: Int) {
        #expect(SegmentSurgery.split(segments: Self.worded, id: 0, atWordIndex: index) == nil)
        #expect(SegmentSurgery.split(segments: Self.worded, id: 99, atWordIndex: 2) == nil)
    }

    @Test("split keeps an elided word attached to the one before it")
    func splitJoinsElisionTails() throws {
        let segments = [
            TranscriptSegment(
                id: 0, start: 0, end: 4, text: "l'altro giorno ieri",
                words: Self.words(["l", "'altro", "giorno", "ieri"], segmentID: 0)
            ),
        ]
        let split = try #require(SegmentSurgery.split(segments: segments, id: 0, atWordIndex: 3))
        #expect(split.segments[0].text == "l'altro giorno")
        #expect(split.segments[1].text == "ieri")
    }

    @Test("split at a fraction without words cuts at the nearest whitespace with interpolated times")
    func splitAtFractionWithoutWords() throws {
        let split = try #require(SegmentSurgery.split(segments: Self.plain, id: 0, atFraction: 0.5))
        let first = split.segments[0]
        let second = split.segments[1]

        #expect(first.text == "Alpha beta")
        #expect(second.text == "gamma")
        #expect(abs(first.end - 10) < 0.0001)
        #expect(second.start == first.end && second.end == 16)
        #expect(first.words == nil && second.words == nil)
    }

    @Test("split at a fraction with words snaps to the nearest word boundary")
    func splitAtFractionSnapsToWords() throws {
        let split = try #require(SegmentSurgery.split(segments: Self.worded, id: 0, atFraction: 0.3))
        #expect(split.segments[0].text == "Uno")
        #expect(split.segments[1].text == "due tre quattro")
    }

    @Test("split at a fraction of a single word returns nil")
    func splitSingleWordReturnsNil() {
        let segments = [TranscriptSegment(id: 0, start: 0, end: 1, text: "Solo")]
        #expect(SegmentSurgery.split(segments: segments, id: 0, atFraction: 0.5) == nil)
    }

    @Test("merge joins text and renumbers words under the first id")
    func mergeWithWords() throws {
        let segments = [
            TranscriptSegment(id: 0, start: 0, end: 2, text: "Uno due", words: Self.words(["Uno", "due"], segmentID: 0)),
            TranscriptSegment(id: 1, start: 2, end: 4, text: "tre", words: Self.words(["tre"], segmentID: 1, start: 2)),
        ]
        let merged = try #require(SegmentSurgery.mergeWithNext(segments: segments, id: 0))

        #expect(merged.count == 1)
        #expect(merged[0].id == 0)
        #expect(merged[0].text == "Uno due tre")
        #expect(merged[0].start == 0 && merged[0].end == 4)
        #expect(merged[0].words?.map(\.id) == ["0-0", "0-1", "0-2"])
    }

    @Test("merge drops word timings when either side has none")
    func mergeWithoutWords() throws {
        let merged = try #require(SegmentSurgery.mergeWithNext(segments: Self.worded, id: 0))
        #expect(merged[0].text == "Uno due tre quattro Coda finale.")
        #expect(merged[0].words == nil)
    }

    @Test("merge of the last segment or an unknown id returns nil")
    func mergeAtTheEndReturnsNil() {
        #expect(SegmentSurgery.mergeWithNext(segments: Self.worded, id: 1) == nil)
        #expect(SegmentSurgery.mergeWithNext(segments: Self.worded, id: 99) == nil)
    }
}
