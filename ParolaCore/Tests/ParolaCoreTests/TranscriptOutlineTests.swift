import Foundation
import Testing
@testable import ParolaCore

@Suite("Transcript outline derivation")
struct TranscriptOutlineTests {
    private func makeSegment(_ id: Int, start: Double, text: String, speaker: String? = nil) -> TranscriptSegment {
        TranscriptSegment(id: id, start: start, end: start + 5, text: text, speaker: speaker)
    }

    private func makeTranscript(segments: [TranscriptSegment]) -> Transcript {
        Transcript(
            schemaVersion: 1,
            segments: segments,
            language: "en",
            modelName: "x",
            sourceURL: nil,
            durationSeconds: segments.last.map { $0.end }
        )
    }

    @Test("empty transcript returns empty outline")
    func emptyTranscript() {
        let entries = TranscriptOutline.entries(for: makeTranscript(segments: []), chapters: [])
        #expect(entries.isEmpty)
    }

    @Test("chapters take precedence over the segment heuristic")
    func chaptersWin() {
        let segments = [makeSegment(1, start: 0, text: "hello there everyone")]
        let chapters = [Chapter(title: "Intro", start: 0), Chapter(title: "Wrap", start: 120)]
        let entries = TranscriptOutline.entries(for: makeTranscript(segments: segments), chapters: chapters)
        #expect(entries.count == 2)
        #expect(entries[0].title == "Intro")
        #expect(entries[1].start == 120)
    }

    @Test("speaker change starts a new outline entry")
    func speakerChange() {
        let segments = [
            makeSegment(1, start: 0, text: "Alice opens the meeting", speaker: "Alice"),
            makeSegment(2, start: 8, text: "Alice continues to outline", speaker: "Alice"),
            makeSegment(3, start: 20, text: "Bob jumps in with thoughts", speaker: "Bob"),
        ]
        let entries = TranscriptOutline.entries(for: makeTranscript(segments: segments), chapters: [])
        #expect(entries.count == 2)
        #expect(entries[0].speaker == "Alice")
        #expect(entries[1].speaker == "Bob")
    }

    @Test("an empty-string speaker does not start a new outline entry")
    func emptyStringSpeakerNoSplit() {
        let segments = [
            makeSegment(1, start: 0, text: "Alice opens the meeting", speaker: "Alice"),
            makeSegment(2, start: 8, text: "the discussion keeps going", speaker: ""),
        ]
        let entries = TranscriptOutline.entries(for: makeTranscript(segments: segments), chapters: [])
        #expect(entries.count == 1)
        #expect(entries[0].speaker == "Alice")
    }

    @Test("an empty-string speaker is normalized to nil in the outline")
    func emptyStringSpeakerNormalized() {
        let segments = [makeSegment(1, start: 0, text: "hello there everyone", speaker: "")]
        let entries = TranscriptOutline.entries(for: makeTranscript(segments: segments), chapters: [])
        #expect(entries.count == 1)
        #expect(entries[0].speaker == nil)
    }

    @Test("long monologue emits a heading every gap window")
    func gapWindow() {
        let segments = (0..<6).map { idx in
            makeSegment(idx, start: Double(idx) * 50, text: "segment \(idx) with several words")
        }
        let entries = TranscriptOutline.entries(for: makeTranscript(segments: segments), chapters: [], gapSeconds: 120)
        #expect(entries.count >= 2)
        #expect(entries.first?.start == 0)
        for pair in zip(entries, entries.dropFirst()) {
            #expect(pair.1.start - pair.0.start >= 120)
        }
    }

    @Test("a whitespace-only transcript yields no outline entries")
    func allEmptyYieldsNothing() {
        let segments = [makeSegment(1, start: 0, text: "   ")]
        let entries = TranscriptOutline.entries(for: makeTranscript(segments: segments), chapters: [])
        #expect(entries.isEmpty)
    }

    @Test("a leading empty segment is skipped; the first real segment anchors the first entry")
    func leadingEmptySkipped() {
        let segments = [
            makeSegment(0, start: 0, text: "\n "),
            makeSegment(1, start: 2, text: "the real opening line"),
        ]
        let entries = TranscriptOutline.entries(for: makeTranscript(segments: segments), chapters: [])
        #expect(entries.count == 1)
        #expect(entries[0].start == 2)
        #expect(entries[0].title == "the real opening line")
    }

    @Test("an empty segment does not steal a heading slot from real content")
    func emptySegmentDoesNotStealHeading() {
        let segments = [
            makeSegment(0, start: 0, text: "first real heading here"),
            makeSegment(1, start: 130, text: "   "),
            makeSegment(2, start: 132, text: "second real heading here"),
        ]
        let entries = TranscriptOutline.entries(for: makeTranscript(segments: segments), chapters: [], gapSeconds: 120)
        #expect(entries.count == 2)
        #expect(entries[0].start == 0)
        #expect(entries[1].start == 132)
        #expect(entries.allSatisfy { !$0.title.contains("Section") })
    }
}
