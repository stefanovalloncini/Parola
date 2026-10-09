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
        let both = LiveTail.attributed(settled: "Quick note.", partial: "For the")
        let runs = both.runs.map {
            (String(both[$0.range].characters), $0[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self])
        }
        #expect(runs.map(\.0) == ["Quick note. ", "For the"])
        #expect(runs[0].1 == DS.Color.primaryText)
        #expect(runs[1].1 == DS.Color.liveTail)

        let settledOnly = LiveTail.attributed(settled: "Quick note.", partial: "")
        #expect(String(settledOnly.characters) == "Quick note.")
        let partialOnly = LiveTail.attributed(settled: "", partial: "For the")
        #expect(String(partialOnly.characters) == "For the")
    }

    private static let paragraph = "The meeting opened with a quick agenda review before the group walked through the numbers and the questions"

    /// Pixels of `view` at twice the scale, white behind it; nil if it couldn't be drawn.
    private func pixels(_ view: some View, width: CGFloat) -> [UInt8]? {
        let renderer = ImageRenderer(content: view.frame(width: width, alignment: .leading).background(Color.white).environment(\.colorScheme, .light))
        renderer.scale = 2
        guard let image = renderer.cgImage, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return drawn ? bytes : nil
    }

    /// How many channels differ by more than a sixteenth between two drawings of the same size.
    private func differing(_ a: [UInt8], _ b: [UInt8]) -> Int {
        zip(a, b).count { abs(Int($0) - Int($1)) > 16 }
    }

    @Test("the caret drawn on its own view sits where the caret at the end of the text did, on the Stage and in the file pane", arguments: [true, false])
    func caretSitsAtTheEnd(onStage: Bool) throws {
        let font = onStage ? DS.Font.liveTranscriptStage : DS.Font.transcript
        let lineSpacing = onStage ? StageLiveText.lineSpacing : DS.Spacing.transcriptLeading
        let width: CGFloat = onStage ? 360 : 300
        let body = Text(verbatim: Self.paragraph)
        let inline = Text("\(body)\(StreamingReveal.caret(visible: true))").font(font).lineSpacing(lineSpacing)
        let laidOver = Text("\(body)\(LiveCaret.placeholder)").font(font).lineSpacing(lineSpacing)
            .textSelection(.enabled)
            .liveCaret(font: font, blinks: false)
        let bare = Text("\(body)\(LiveCaret.placeholder)").font(font).lineSpacing(lineSpacing)
        let old = try #require(pixels(inline, width: width))
        let new = try #require(pixels(laidOver, width: width))
        let none = try #require(pixels(bare, width: width))
        #expect(old.count == new.count && old.count == none.count, "the caret changed the text's size")
        #expect(differing(old, none) > 40, "the text with no caret should lack the caret's pixels")
        #expect(differing(old, new) <= 8, "\(differing(old, new)) channels differ from the caret in the text")
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
