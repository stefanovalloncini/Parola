import AppKit
import SwiftUI
import Testing
import ParolaCore
@testable import Parola

@MainActor
@Suite("Stage live text")
struct StageLiveTextTests {
    private func segment(_ id: Int, _ start: Double, _ end: Double, _ text: String, speaker: String? = nil) -> TranscriptSegment {
        TranscriptSegment(id: id, start: start, end: end, text: text, speaker: speaker)
    }

    @Test("a pause or a new speaker opens a paragraph, as in the finished transcript")
    func paragraphs() {
        let paragraphs = LiveParagraphs.make(from: [
            segment(0, 0, 2, " Quick note."),
            segment(1, 2.5, 4, "For the launch video."),
            segment(2, 6, 7, "Second idea."),
            segment(3, 7.2, 8, "   "),
            segment(4, 8.1, 9, "Sounds good.", speaker: "Giulia"),
        ])
        #expect(paragraphs.map(\.text) == ["Quick note. For the launch video.", "Second idea.", "Sounds good."])
        #expect(paragraphs.map(\.id) == [0, 2, 4])
    }

    @Test("the Stage keeps the newest segments, one line per paragraph")
    func settledText() {
        let segments = (0..<20).map { segment($0, Double($0) * 3, Double($0) * 3 + 1, "Line \($0).") }
        let text = StageLiveText.settledText(segments)
        #expect(text.hasPrefix("Line 4."))
        #expect(text.hasSuffix("Line 19."))
        #expect(text.split(separator: "\n").count == 16)
    }

    @Test("settled words are primary, the fresh tail grey, and the caret follows them")
    func tailColors() {
        let both = LiveTail.attributed(settled: "Quick note.", partial: "For the", caretVisible: true)
        let runs = both.runs.map {
            (String(both[$0.range].characters), $0[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self])
        }
        #expect(runs.map(\.0) == ["Quick note. ", "For the", "\u{258F}"])
        #expect(runs[0].1 == DS.Color.primaryText)
        #expect(runs[1].1 == DS.Color.liveTail)

        let settledOnly = LiveTail.attributed(settled: "Quick note.", partial: "", caretVisible: false)
        #expect(String(settledOnly.characters) == "Quick note.\u{258F}")
        let partialOnly = LiveTail.attributed(settled: "", partial: "For the", caretVisible: true)
        #expect(String(partialOnly.characters) == "For the\u{258F}")
    }

    private func height(lines: Int) -> CGFloat {
        let text = Array(repeating: "Hxg", count: lines).joined(separator: "\n")
        let view = Text(verbatim: text)
            .font(DS.Font.liveTranscriptStage)
            .lineSpacing(StageLiveText.lineSpacing)
        return NSHostingView(rootView: view).fittingSize.height
    }

    @Test("the column shows four whole lines of the Stage face, and a fifth only as it fades out")
    func fourLines() {
        #expect(StageLiveText.visibleLines == 4)
        #expect(height(lines: StageLiveText.visibleLines) <= StageLiveText.height)
        #expect(height(lines: StageLiveText.visibleLines + 1) > StageLiveText.height)
        #expect(height(lines: 1) <= StageLiveText.minHeight)
    }
}
