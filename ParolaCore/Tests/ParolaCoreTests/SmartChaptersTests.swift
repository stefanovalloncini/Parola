import Foundation
import Testing
@testable import ParolaCore

@Suite("Smart chapters parser")
struct SmartChaptersTests {
    @Test("parses MM:SS chapter lines")
    func parsesMinuteSeconds() {
        let result = SmartChapters.parseResponse("""
        00:00 Welcome and introductions
        03:21 Quarter review
        09:50 Action items
        """)
        #expect(result.count == 3)
        #expect(result[0].start == 0)
        #expect(result[0].title == "Welcome and introductions")
        #expect(result[1].start == 201)
        #expect(result[2].start == 590)
    }

    @Test("parses HH:MM:SS chapter lines")
    func parsesHours() {
        let result = SmartChapters.parseResponse("00:00 Intro\n1:05:30 Closing")
        #expect(result.count == 2)
        #expect(result[1].start == 3930)
        #expect(result[1].title == "Closing")
    }

    @Test("ignores lines without a leading timestamp")
    func skipsNoise() {
        let result = SmartChapters.parseResponse("""
        Here are the chapters:
        00:00 Intro
        - some bullet
        02:15 Discussion
        """)
        #expect(result.count == 2)
        #expect(result[0].title == "Intro")
        #expect(result[1].title == "Discussion")
    }

    @Test("strips surrounding quotes and dashes from titles")
    func cleansTitles() {
        let result = SmartChapters.parseResponse("""
        00:00 - "Welcome"
        02:00 — Discussion
        """)
        #expect(result[0].title == "Welcome")
        #expect(result[1].title == "Discussion")
    }

    @Test("parses chapter lines with a leading bullet")
    func parsesBulletedLines() {
        let result = SmartChapters.parseResponse("- 00:00 Intro\n* 02:15 Discussion\n• 05:00 Wrap-up")
        #expect(result.map(\.title) == ["Intro", "Discussion", "Wrap-up"])
        #expect(result.map(\.start) == [0, 135, 300])
    }

    @Test("parses bulleted chapter lines with a tab after the bullet")
    func parsesBulletedTabLines() {
        let result = SmartChapters.parseResponse("-\t00:00 Intro\n*\t02:15 Discussion\n• \t05:00 Wrap-up")
        #expect(result.map(\.title) == ["Intro", "Discussion", "Wrap-up"])
        #expect(result.map(\.start) == [0, 135, 300])
    }

    @Test("parses numbered-list chapter lines")
    func parsesNumberedLines() {
        let result = SmartChapters.parseResponse("1. 00:00 Intro\n2. 02:15 Discussion\n3) 05:00 Wrap-up")
        #expect(result.map(\.title) == ["Intro", "Discussion", "Wrap-up"])
        #expect(result.map(\.start) == [0, 135, 300])
    }

    @Test("parses chapter lines with stacked list markers")
    func parsesStackedMarkers() {
        let result = SmartChapters.parseResponse("1. - 00:00 Intro\n- 2) 02:15 Discussion\n* • 05:00 Wrap-up")
        #expect(result.map(\.title) == ["Intro", "Discussion", "Wrap-up"])
        #expect(result.map(\.start) == [0, 135, 300])
    }

    @Test("parses chapter lines with a markdown-bold timestamp")
    func parsesBoldTimestamp() {
        let result = SmartChapters.parseResponse("**00:00** Intro\n**02:15** Discussion")
        #expect(result.map(\.title) == ["Intro", "Discussion"])
        #expect(result.map(\.start) == [0, 135])
    }

    @Test("parses chapter lines wrapped entirely in bold")
    func parsesBoldWholeLine() {
        let result = SmartChapters.parseResponse("**00:00 Intro**\n**02:15 Discussion**")
        #expect(result.map(\.title) == ["Intro", "Discussion"])
        #expect(result.map(\.start) == [0, 135])
    }

    @Test("parses chapter lines with a bracketed timestamp")
    func parsesBracketedTimestamp() {
        let result = SmartChapters.parseResponse("[00:00] Intro\n[02:15] Discussion")
        #expect(result.map(\.title) == ["Intro", "Discussion"])
        #expect(result.map(\.start) == [0, 135])
    }

    @Test("keeps chapters with fractional-second timestamps")
    func parsesFractionalSeconds() {
        let result = SmartChapters.parseResponse("00:00 Intro\n00:30.5 Deep dive\n1:00:30.25 Wrap")
        #expect(result.map(\.title) == ["Intro", "Deep dive", "Wrap"])
        #expect(result.map(\.start) == [0, 30.5, 3630.25])
    }

    @Test("a numbered marker does not turn a decimal into a timestamp")
    func numberedMarkerKeepsDecimalAsNoise() {
        let result = SmartChapters.parseResponse("1. 3.5 mg of caffeine\n2. 00:00 Intro")
        #expect(result.map(\.title) == ["Intro"])
        #expect(result.map(\.start) == [0])
    }

    @Test("empty input yields empty list")
    func emptyInput() {
        #expect(SmartChapters.parseResponse("").isEmpty)
        #expect(SmartChapters.parseResponse("\n\n\n").isEmpty)
    }

    @Test("rejects entries past the transcript duration when clamping")
    func clampsDuration() {
        let raw = "00:00 Intro\n10:00 Middle\n40:00 Outro"
        let result = SmartChapters.parseResponse(raw, maxSeconds: 1800)
        #expect(result.count == 2)
        #expect(result.last?.title == "Middle")
    }

    @Test("rejects timestamps that go backwards")
    func dropsBacktracking() {
        let result = SmartChapters.parseResponse("00:00 A\n05:00 B\n02:00 C")
        #expect(result.map(\.title) == ["A", "B"])
    }

    @Test("caps chapters at the latest segment end, not array order")
    func capUsesMaxEndOnOutOfOrderSegments() async throws {
        let transcript = Transcript(
            segments: [
                TranscriptSegment(id: 0, start: 540, end: 600, text: "The late topic discussed last."),
                TranscriptSegment(id: 1, start: 0, end: 60, text: "The early introduction first."),
            ],
            language: "en",
            modelName: "tiny"
        )
        let model = MockLanguageModel(scriptedResponses: ["00:00 Intro\n09:00 Late discussion"])
        let result = try await SmartChapters.generate(for: transcript, model: model, budget: TokenBudget(tokens: 3500))
        #expect(result.map(\.title) == ["Intro", "Late discussion"])
    }
}

@Suite("Timecode parser")
struct TimecodeParserTests {
    @Test("parses MM:SS")
    func mmss() {
        #expect(Timecode.parse("03:21") == 201)
        #expect(Timecode.parse("00:00") == 0)
    }

    @Test("parses HH:MM:SS and H:MM:SS")
    func hhmmss() {
        #expect(Timecode.parse("01:05:30") == 3930)
        #expect(Timecode.parse("1:05:30") == 3930)
    }

    @Test("rejects garbage")
    func rejectsGarbage() {
        #expect(Timecode.parse("foo") == nil)
        #expect(Timecode.parse("1:2") == 62)
        #expect(Timecode.parse("99:99:99:99") == nil)
    }
}
