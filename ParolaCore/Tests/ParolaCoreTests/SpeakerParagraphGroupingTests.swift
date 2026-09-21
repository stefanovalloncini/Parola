import Foundation
import Testing
@testable import ParolaCore

@Suite("Speaker paragraph grouping")
struct SpeakerParagraphGroupingTests {

    private func diarized() -> [TranscriptSegment] {
        [
            TranscriptSegment(id: 0, start: 0, end: 2, text: "Good morning.", speaker: "Ada"),
            TranscriptSegment(id: 1, start: 2, end: 5, text: "How did the run go?", speaker: "Ada"),
            TranscriptSegment(id: 2, start: 5, end: 8, text: "Faster than last week.", speaker: "Grace"),
            TranscriptSegment(id: 3, start: 8, end: 11, text: "Good to hear.", speaker: "Ada"),
        ]
    }

    @Test("none leaves the segments untouched")
    func noneIsIdentity() {
        #expect(ExportGrouping.none.apply(to: diarized()) == diarized())
    }

    @Test("consecutive turns by one speaker merge into a single segment")
    func mergesConsecutiveTurns() {
        let merged = ExportGrouping.speakerParagraphs.apply(to: diarized())
        #expect(merged.count == 3)
        #expect(merged[0].text == "Good morning. How did the run go?")
        #expect(merged[0].start == 0)
        #expect(merged[0].end == 5)
        #expect(merged[0].speaker == "Ada")
        #expect(merged[1].text == "Faster than last week.")
        #expect(merged[2].text == "Good to hear.")
    }

    @Test("the merged segment keeps the first segment's id")
    func keepsFirstIdentifier() {
        let merged = ExportGrouping.speakerParagraphs.apply(to: diarized())
        #expect(merged.map(\.id) == [0, 2, 3])
    }

    @Test("word timings of the merged segments are concatenated")
    func concatenatesWordTimings() {
        let segments = [
            TranscriptSegment(
                id: 0, start: 0, end: 1, text: "Hello", speaker: "Ada",
                words: [WordTiming(id: "0-0", word: "Hello", start: 0, end: 1, probability: 1)]
            ),
            TranscriptSegment(
                id: 1, start: 1, end: 2, text: "again", speaker: "Ada",
                words: [WordTiming(id: "1-0", word: "again", start: 1, end: 2, probability: 1)]
            ),
        ]
        let merged = ExportGrouping.speakerParagraphs.apply(to: segments)
        #expect(merged.count == 1)
        #expect(merged[0].words?.map(\.word) == ["Hello", "again"])
    }

    @Test("a run where only one segment has word timings loses them")
    func partialWordTimingsAreDropped() {
        let segments = [
            TranscriptSegment(id: 0, start: 0, end: 1, text: "Hello", speaker: "Ada"),
            TranscriptSegment(
                id: 1, start: 1, end: 2, text: "again", speaker: "Ada",
                words: [WordTiming(id: "1-0", word: "again", start: 1, end: 2, probability: 1)]
            ),
        ]
        let merged = ExportGrouping.speakerParagraphs.apply(to: segments)
        #expect(merged.count == 1)
        #expect(merged[0].words == nil)
    }

    @Test("segments without a speaker merge with each other")
    func unlabelledSegmentsMerge() {
        let segments = [
            TranscriptSegment(id: 0, start: 0, end: 1, text: "One."),
            TranscriptSegment(id: 1, start: 1, end: 2, text: "Two."),
            TranscriptSegment(id: 2, start: 2, end: 3, text: "Three.", speaker: "Ada"),
        ]
        let merged = ExportGrouping.speakerParagraphs.apply(to: segments)
        #expect(merged.count == 2)
        #expect(merged[0].text == "One. Two.")
        #expect(merged[0].speaker == nil)
    }

    @Test("a blank segment adds no separator")
    func blankSegmentsDoNotPadTheText() {
        let segments = [
            TranscriptSegment(id: 0, start: 0, end: 1, text: "One.", speaker: "Ada"),
            TranscriptSegment(id: 1, start: 1, end: 2, text: "   ", speaker: "Ada"),
            TranscriptSegment(id: 2, start: 2, end: 3, text: "Two.", speaker: "Ada"),
        ]
        let merged = ExportGrouping.speakerParagraphs.apply(to: segments)
        #expect(merged.count == 1)
        #expect(merged[0].text == "One. Two.")
    }

    @Test("an empty segment list stays empty")
    func emptyStaysEmpty() {
        #expect(ExportGrouping.speakerParagraphs.apply(to: []).isEmpty)
    }

    @Test("the txt export renders one line per speaker turn")
    func txtHonoursGrouping() throws {
        var spec = ExportSpec.standard(for: .txt)
        spec.options.grouping = .speakerParagraphs
        let transcript = Transcript(segments: diarized(), language: "en", modelName: "x")
        let out = try Exporters.exporter(for: spec).renderText(transcript)
        #expect(out == """
        Ada: Good morning. How did the run go?
        Grace: Faster than last week.
        Ada: Good to hear.

        """)
    }

    @Test("the srt export merges a speaker's consecutive cues into one")
    func srtHonoursGrouping() throws {
        var spec = ExportSpec.standard(for: .srt)
        spec.options.grouping = .speakerParagraphs
        let transcript = Transcript(segments: diarized(), language: "en", modelName: "x")
        let out = try Exporters.exporter(for: spec).renderText(transcript)
        #expect(out.contains("Good morning. How did the run go?"))
        #expect(out.contains("00:00:00,000 --> 00:00:05,000"))
        #expect(out.split(separator: "\n").filter { $0.contains("-->") }.count == 3)
    }

    @Test("the json export merges the segments it writes")
    func jsonHonoursGrouping() throws {
        var spec = ExportSpec.standard(for: .json)
        spec.options.grouping = .speakerParagraphs
        let transcript = Transcript(segments: diarized(), language: "en", modelName: "x")
        let data = try Exporters.exporter(for: spec).render(transcript)
        let decoded = try JSONDecoder().decode(Transcript.self, from: data)
        #expect(decoded.segments.count == 3)
        #expect(decoded.segments[0].text == "Good morning. How did the run go?")
    }
}
