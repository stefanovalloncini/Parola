import Foundation
import Testing
@testable import ParolaCore

@Suite("Summary windowing")
struct SummaryWindowingTests {
    private func segment(_ i: Int) -> TranscriptSegment {
        let text = "marker\(i) " + String(repeating: "lorem ipsum dolor sit amet ", count: 22)
        return TranscriptSegment(id: i, start: Double(i) * 300, end: Double(i) * 300 + 200, text: text)
    }

    private func longTranscript(segmentCount: Int = 4) -> Transcript {
        Transcript(
            segments: (0..<segmentCount).map(segment),
            language: "en",
            modelName: "tiny"
        )
    }

    private func windowResponse(_ i: Int, start: Double) -> String {
        """
        SUMMARY:
        Window \(i) summary.

        CHAPTERS:
        \(Timecode.format(start)) Chapter \(i)
        """
    }

    @Test("under budget sends exactly one call with today's prompt")
    func underBudgetSingleShot() async throws {
        let transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "Hello world.")],
            language: "en",
            modelName: "tiny"
        )
        let model = MockLanguageModel(scriptedResponses: ["""
        SUMMARY:
        Short greeting.

        CHAPTERS:
        00:00 Hello
        """])
        let summary = try await SummaryService().summarise(transcript, model: model)
        #expect(summary.text == "Short greeting.")
        let prompts = await model.receivedPrompts
        #expect(prompts == [SummaryService.buildPrompt(for: transcript)])
    }

    @Test("over budget summarises each window then reduces")
    func overBudgetMapReduce() async throws {
        let transcript = longTranscript()
        let budget = 200
        let windows = SummaryService.windows(for: transcript, budgetTokens: budget)
        #expect(windows.count == 4)

        var responses = windows.enumerated().map { i, window in
            windowResponse(i, start: window.segments.first?.start ?? 0)
        }
        responses.append("""
        SUMMARY:
        Combined overview of everything.

        CHAPTERS:
        00:00 Reduce chapters are ignored
        """)
        let model = MockLanguageModel(scriptedResponses: responses)

        let summary = try await SummaryService(budgetTokens: budget).summarise(transcript, model: model)

        let prompts = await model.receivedPrompts
        #expect(prompts.count == windows.count + 1)
        for (i, window) in windows.enumerated() {
            #expect(prompts[i] == SummaryService.buildPrompt(for: window))
            #expect(prompts[i].contains("marker\(i) "))
            for other in 0..<windows.count where other != i {
                #expect(!prompts[i].contains("marker\(other) "))
            }
        }
        #expect(prompts[1].contains("05:00  marker1"))
        #expect(prompts[3].contains("15:00  marker3"))
        let reducePrompt = try #require(prompts.last)
        #expect(reducePrompt.contains("Window 0 summary."))
        #expect(reducePrompt.contains("Window 3 summary."))
        #expect(!reducePrompt.contains("marker0 "))

        #expect(summary.text == "Combined overview of everything.")
        #expect(summary.chapters.map(\.title) == ["Chapter 0", "Chapter 1", "Chapter 2", "Chapter 3"])
        #expect(summary.chapters.map(\.start) == [0, 300, 600, 900])
    }

    @Test("windows cover all segments in order at segment boundaries")
    func windowsCoverSegments() {
        let transcript = longTranscript(segmentCount: 7)
        let windows = SummaryService.windows(for: transcript, budgetTokens: 400)
        #expect(windows.count > 1)
        #expect(windows.flatMap(\.segments) == transcript.segments)
        for window in windows {
            #expect(TokenBudget.estimateTokens(SummaryService.buildPrompt(for: window)) <= 400)
        }
    }

    @Test("blank segments cost nothing and never open a window of their own")
    func blankSegmentsAreFree() throws {
        var segments = (0..<4).map(segment)
        for i in 0..<4 {
            segments.insert(TranscriptSegment(id: 100 + i, start: Double(i) * 300 + 250, end: Double(i) * 300 + 260, text: "  \n"), at: i * 2 + 1)
        }
        let transcript = Transcript(segments: segments, language: "en", modelName: "tiny")
        let windows = SummaryService.windows(for: transcript, budgetTokens: 200)
        #expect(windows.count == 4)
        #expect(windows.flatMap(\.segments) == transcript.segments)
        let prompted = SummaryService.windowPrompts(
            for: transcript,
            lines: transcript.segments.map(TranscriptPromptContext.timestampedLine(for:)),
            budgetTokens: 200
        )
        #expect(prompted.map(\.prompt) == windows.map { SummaryService.buildPrompt(for: $0) })
    }

    @Test("a failed window propagates and no reduce call happens")
    func windowFailurePropagates() async throws {
        let transcript = longTranscript()
        let budget = 200
        let model = MockLanguageModel(
            scriptedResponses: [windowResponse(0, start: 0)],
            failOnCallIndex: 1
        )
        await #expect(throws: SummaryService.FailureReason.self) {
            _ = try await SummaryService(budgetTokens: budget).summarise(transcript, model: model)
        }
        let count = await model.receivedHistories.count
        #expect(count == 2)
    }

    @Test("windowed summarise merges action items across parts then appends the reduce step's own")
    func actionItemsMergeAcrossWindows() async throws {
        let transcript = longTranscript(segmentCount: 2)
        let budget = 200
        let windows = SummaryService.windows(for: transcript, budgetTokens: budget)
        #expect(windows.count == 2)

        let responses = [
            """
            SUMMARY:
            Window 0 summary.

            CHAPTERS:
            00:00 Chapter 0

            ACTION ITEMS:
            - Send the deck
            - Book the room
            """,
            """
            SUMMARY:
            Window 1 summary.

            CHAPTERS:
            05:00 Chapter 1

            ACTION ITEMS:
            - book the room
            - Email the client
            """,
            """
            SUMMARY:
            Combined overview.

            CHAPTERS:
            00:00 Reduce chapters are ignored

            ACTION ITEMS:
            - Email the client
            - Follow up next week
            """,
        ]
        let model = MockLanguageModel(scriptedResponses: responses)

        let summary = try await SummaryService(budgetTokens: budget).summarise(transcript, model: model)

        #expect(summary.actionItems == ["Send the deck", "Book the room", "Email the client", "Follow up next week"])
    }

    @Test("merged chapters drop consecutive duplicate titles but keep repeats apart")
    func chapterDedupe() {
        let merged = SummaryService.mergeChapters([
            Chapter(title: "Q&A", start: 100),
            Chapter(title: "Intro", start: 0),
            Chapter(title: "intro", start: 30),
            Chapter(title: "Q&A", start: 900),
        ])
        #expect(merged.map(\.title) == ["Intro", "Q&A", "Q&A"])
        #expect(merged.map(\.start) == [0, 100, 900])
    }
}
