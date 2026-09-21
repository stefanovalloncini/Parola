import Foundation
import SwiftUI
import Testing
@testable import Parola
import ParolaCore

@Suite("Demo transcript summary")
struct DemoTranscriptSummaryTests {

    private func script(duration: Double, words: Int = 3) -> DemoScript {
        DemoScript(
            text: "x",
            speaker: "Speaker 1",
            duration: duration,
            levelRate: 20,
            levels: [],
            words: (0..<words).map { DemoScript.Word(text: "w\($0)", start: Double($0), end: Double($0) + 0.5) }
        )
    }

    @Test("the duration reads as minutes and seconds, rounded to the nearest second")
    func durationLabel() {
        #expect(DemoTranscriptSummary(script: script(duration: 6.964)).durationLabel == "0:07")
        #expect(DemoTranscriptSummary(script: script(duration: 65.2)).durationLabel == "1:05")
        #expect(DemoTranscriptSummary(script: script(duration: 0)).durationLabel == "0:00")
        #expect(DemoTranscriptSummary(script: script(duration: 599.5)).durationLabel == "10:00")
    }

    @Test("the word count comes from the script, and a script without words has none")
    func wordCount() {
        #expect(DemoTranscriptSummary(script: script(duration: 7, words: 24)).wordCount == 24)
        #expect(DemoTranscriptSummary(script: .placeholder).wordCount == nil)
    }

    @Test("the footer offers five formats the app really writes")
    func exportFormats() {
        #expect(DemoTranscriptSummary.exportFormats == [.txt, .md, .srt, .docx, .pdf])
        #expect(DemoTranscriptSummary.exportFormats.allSatisfy { ExportFormat.allCases.contains($0) })
    }

    @Test("each format wears its short name")
    func labels() {
        #expect(DemoTranscriptSummary.label(for: .txt) == "Text")
        #expect(DemoTranscriptSummary.label(for: .md) == "Markdown")
        #expect(DemoTranscriptSummary.label(for: .srt) == "SRT")
        #expect(DemoTranscriptSummary.label(for: .docx) == "Word")
        #expect(DemoTranscriptSummary.label(for: .pdf) == "PDF")
    }
}
