import Foundation
import Testing
@testable import ParolaCore

@Suite("Summary parser")
struct SummaryServiceTests {
    @Test("clock parsing handles MM:SS and H:MM:SS")
    func clock() {
        #expect(SummaryService.parseClock("01:30") == 90)
        #expect(SummaryService.parseClock("1:02:03") == 3723)
        #expect(SummaryService.parseClock("not a time") == nil)
    }

    @Test("chapter line parses timestamp + title")
    func chapter() {
        let c = SummaryService.parseChapter("00:30 Opening greetings")
        #expect(c?.title == "Opening greetings")
        #expect(c?.start == 30)
    }

    @Test("chapter line handles bullet prefixes")
    func chapterBullet() {
        let c = SummaryService.parseChapter("- 01:15 Speaker introduces topic")
        #expect(c?.title == "Speaker introduces topic")
        #expect(c?.start == 75)
    }

    @Test("full response parse extracts summary + chapters")
    func fullResponse() {
        let response = """
        SUMMARY:
        The speaker introduces Parola and explains how on-device transcription works.

        CHAPTERS:
        00:00 Welcome and intro
        00:45 How WhisperKit works
        02:10 Closing thoughts
        """
        let summary = SummaryService.parse(response)
        #expect(summary.text.contains("Parola"))
        #expect(summary.chapters.count == 3)
        #expect(summary.chapters[0].start == 0)
        #expect(summary.chapters[1].start == 45)
        #expect(summary.chapters[2].start == 130)
    }

    @Test("malformed CHAPTERS section yields empty list, summary intact")
    func malformed() {
        let response = """
        SUMMARY:
        A one-sentence summary.

        CHAPTERS:
        garbage line
        another garbage line
        """
        let summary = SummaryService.parse(response)
        #expect(summary.text == "A one-sentence summary.")
        #expect(summary.chapters.isEmpty)
    }

    @Test("Transcript stores summary and round-trips through Codable")
    func transcriptRoundTrip() throws {
        var t = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "Hi")],
            language: "en",
            modelName: "tiny"
        )
        t.summary = Summary(text: "Greeting.", chapters: [Chapter(title: "Hello", start: 0)])
        let data = try JSONEncoder().encode(t)
        let decoded = try JSONDecoder().decode(Transcript.self, from: data)
        #expect(decoded.summary?.text == "Greeting.")
        #expect(decoded.summary?.chapters.first?.title == "Hello")
    }
}
