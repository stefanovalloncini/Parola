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

    @Test("clock parsing rejects non-finite, non-decimal, and out-of-range times", arguments: [
        "0:inf",
        "0:nan",
        "0:1e3",
        "0:0x1p4",
        "0:-5",
        "1:00:inf",
        "-5:00",
        "99999999:00",
        "1000:00:01",
    ])
    func clockRejectsPoison(_ input: String) {
        #expect(SummaryService.parseClock(input) == nil)
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

        let dot = SummaryService.parseChapter("• 01:15 Speaker introduces topic")
        #expect(dot?.title == "Speaker introduces topic")
        #expect(dot?.start == 75)
    }

    @Test("chapter line separated by a tab still parses")
    func chapterTabSeparated() {
        let c = SummaryService.parseChapter("00:30\tOpening greetings")
        #expect(c?.title == "Opening greetings")
        #expect(c?.start == 30)
    }

    @Test("chapter title strips surrounding bullets and quotes")
    func chapterCleansTitle() {
        let quoted = SummaryService.parseChapter("00:30 - \"Welcome\"")
        #expect(quoted?.title == "Welcome")

        let dashed = SummaryService.parseChapter("02:00 — Discussion")
        #expect(dashed?.title == "Discussion")
    }

    @Test("chapter line with a bold-markdown timestamp still parses")
    func chapterBoldTimestamp() {
        let bold = SummaryService.parseChapter("**00:00** Welcome and intro")
        #expect(bold?.title == "Welcome and intro")
        #expect(bold?.start == 0)

        let wholeLine = SummaryService.parseChapter("**01:30 Roadmap review**")
        #expect(wholeLine?.title == "Roadmap review")
        #expect(wholeLine?.start == 90)

        let underscored = SummaryService.parseChapter("_02:10_ Closing thoughts")
        #expect(underscored?.title == "Closing thoughts")
        #expect(underscored?.start == 130)
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

    @Test("a chapter line with a malformed timestamp is dropped, valid ones kept")
    func dropsMalformedChapterTime() {
        let response = """
        SUMMARY:
        A summary.

        CHAPTERS:
        00:00 Good intro
        0:inf Poisoned chapter
        01:30 Good outro
        """
        let summary = SummaryService.parse(response)
        #expect(summary.chapters.map(\.title) == ["Good intro", "Good outro"])
    }

    @Test("two-paragraph summary preserves both paragraphs joined by a blank line")
    func twoParagraphSummary() {
        let response = """
        SUMMARY:
        First paragraph sentence.

        Second paragraph sentence.

        CHAPTERS:
        00:00 Intro
        """
        let summary = SummaryService.parse(response)
        #expect(summary.text.contains("First paragraph"))
        #expect(summary.text.contains("Second paragraph"))
        #expect(summary.text.contains("\n\n"))
    }

    @Test("summary collapses inner whitespace runs without losing paragraph breaks")
    func collapsesInnerWhitespace() {
        let response = """
        SUMMARY:
        The   speaker    paused.

        Then they\tcontinued.

        CHAPTERS:
        00:00 Intro
        """
        let summary = SummaryService.parse(response)
        #expect(summary.text == "The speaker paused.\n\nThen they continued.")
    }

    @Test("bold markdown section headers are still recognized")
    func boldMarkdownHeaders() {
        let response = """
        **SUMMARY:**
        The team reviewed the roadmap.

        **CHAPTERS:**
        00:00 Intro
        01:30 Roadmap
        """
        let summary = SummaryService.parse(response)
        #expect(summary.text == "The team reviewed the roadmap.")
        #expect(summary.chapters.map(\.start) == [0, 90])
    }

    @Test("markdown header (##) section markers are recognized")
    func atxMarkdownHeaders() {
        let response = """
        ## SUMMARY:
        A short recap.

        ## CHAPTERS:
        00:00 Start
        """
        let summary = SummaryService.parse(response)
        #expect(summary.text == "A short recap.")
        #expect(summary.chapters.first?.title == "Start")
    }

    @Test("inline summary text after a bold header is captured without the markdown")
    func boldHeaderInlineText() {
        let response = """
        **SUMMARY:** It went well.

        CHAPTERS:
        00:00 Begin
        """
        let summary = SummaryService.parse(response)
        #expect(summary.text == "It went well.")
    }

    @Test("summarise injects an external model so callers can swap providers")
    func summariseWithInjectedModel() async throws {
        let model = MockLanguageModel(scriptedResponses: ["""
        SUMMARY:
        It was a meeting.

        CHAPTERS:
        00:00 Start
        """])
        let service = SummaryService()
        let transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "Hi")],
            language: "en",
            modelName: "tiny"
        )
        let summary = try await service.summarise(transcript, model: model)
        #expect(summary.text == "It was a meeting.")
        #expect(summary.chapters.first?.title == "Start")
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
