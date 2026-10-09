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

    enum CaretCase: String, CaseIterable, CustomTestStringConvertible {
        case stage, pane, paneRightToLeft, stageRightToLeft
        var testDescription: String { rawValue }

        var rightToLeft: Bool { self == .paneRightToLeft || self == .stageRightToLeft }
        var settled: String {
            rightToLeft
                ? "הפגישה נפתחה בסקירה קצרה של סדר היום לפני שהקבוצה עברה על המספרים ועל השאלות"
                : "The meeting opened with a quick agenda review before the group walked through the numbers"
        }
        var partial: String { rightToLeft ? "שעלו בדרך" : "and the questions" }
        var width: CGFloat { self == .stage || self == .stageRightToLeft ? 360 : 300 }
    }

    /// Pixels of `view` at twice the scale, white behind it; nil if it couldn't be drawn.
    private func pixels(_ view: some View, width: CGFloat, scheme: ColorScheme = .light) -> [UInt8]? {
        let renderer = ImageRenderer(content: view.frame(width: width, alignment: .leading).background(Color.white).environment(\.colorScheme, scheme))
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

    /// Reference Stage text with the caret inline, a character at its end.
    private func inlineStage(_ settled: String, _ partial: String, caretVisible: Bool) -> some View {
        var text = LiveTail.attributed(settled: settled, partial: partial)
        var caret = AttributedString(StreamingReveal.caretGlyph)
        caret.foregroundColor = DS.Color.accentInk.opacity(caretVisible ? 1 : 0)
        text.append(caret)
        return Text(text)
            .font(DS.Font.liveTranscriptStage)
            .lineSpacing(StageLiveText.lineSpacing)
            .contentTransition(.identity)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Reference pane text with the caret inline.
    private func inlinePane(_ text: AttributedString, caretVisible: Bool) -> some View {
        Text("\(Text(text))\(StreamingReveal.caret(visible: caretVisible))")
            .font(DS.Font.transcript)
            .lineSpacing(DS.Spacing.transcriptLeading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .contentTransition(.interpolate)
    }

    @Test("the caret drawn on its own view sits where the caret at the end of the text did, on the Stage and in the file pane", arguments: CaretCase.allCases)
    func caretSitsAtTheEnd(_ place: CaretCase) throws {
        let old, new, none: [UInt8]
        switch place {
        case .stage, .stageRightToLeft:
            old = try #require(pixels(inlineStage(place.settled, place.partial, caretVisible: true), width: place.width))
            none = try #require(pixels(inlineStage(place.settled, place.partial, caretVisible: false), width: place.width))
            let tail = LiveTail(
                settled: place.settled, partial: place.partial, font: DS.Font.liveTranscriptStage,
                lineSpacing: StageLiveText.lineSpacing, blinks: false
            )
            new = try #require(pixels(tail, width: place.width))
        case .pane, .paneRightToLeft:
            let text = StreamingReveal.attributed(settled: place.settled, fresh: " " + place.partial)
            old = try #require(pixels(inlinePane(text, caretVisible: true), width: place.width))
            none = try #require(pixels(inlinePane(text, caretVisible: false), width: place.width))
            let pane = TranscribingText(text: text, spoken: place.settled, blinks: false)
                .frame(maxWidth: .infinity, alignment: .leading)
            new = try #require(pixels(pane, width: place.width))
        }
        #expect(old.count == new.count && old.count == none.count, "the caret changed the text's size")
        #expect(differing(old, none) > 40, "the text with no caret should lack the caret's pixels")
        #expect(differing(old, new) <= 8, "\(differing(old, new)) channels differ from the caret in the text")
    }

    /// The average colour of what a hosted view drew over its white, as the window shows it now; nil if it drew nothing.
    private func ink(of host: NSView) -> [Int]? {
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        var sums = [0, 0, 0], count = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let rgb = [color.redComponent, color.greenComponent, color.blueComponent].map { Int($0 * 255) }
                guard rgb.contains(where: { $0 < 200 }) else { continue }
                for channel in 0..<3 { sums[channel] += rgb[channel] }
                count += 1
            }
        }
        return count > 0 ? sums.map { $0 / count } : nil
    }

    @Test("a caret that holds still takes the new ink when light switches to dark")
    func steadyCaretFollowsTheAppearance() async throws {
        let scheme = CaretScheme()
        let hosted = HostedWindow(SchemedCaret(scheme: scheme), width: 60, height: 60)
        defer { hosted.close() }
        let light = try #require(ink(of: hosted.host))
        scheme.value = .dark
        await settle(for: .milliseconds(100))
        let switched = try #require(ink(of: hosted.host))

        let darkScheme = CaretScheme()
        darkScheme.value = .dark
        let fresh = HostedWindow(SchemedCaret(scheme: darkScheme), width: 60, height: 60)
        defer { fresh.close() }
        let dark = try #require(ink(of: fresh.host))
        #expect(light != dark, "the accent ink should differ between light and dark")
        #expect(switched == dark, "after the switch the caret reads \(switched), a dark one \(dark), the light one \(light)")
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

@MainActor
@Observable
private final class CaretScheme {
    var value: ColorScheme = .light
}

/// The Stage's caret alone, steady, on white, in whichever scheme it is handed.
private struct SchemedCaret: View {
    let scheme: CaretScheme

    var body: some View {
        LiveTail(settled: "", partial: "", font: DS.Font.liveTranscriptStage, lineSpacing: StageLiveText.lineSpacing, blinks: false)
            .frame(width: 60, height: 60, alignment: .topLeading)
            .background(Color.white)
            .environment(\.colorScheme, scheme.value)
    }
}
