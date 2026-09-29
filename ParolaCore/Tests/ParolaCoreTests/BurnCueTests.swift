import Foundation
import CoreText
import Testing
@testable import ParolaCore

@Suite("Burn cues")
struct BurnCueTests {
    private let portrait = CGSize(width: 720, height: 1280)
    private let longText = """
        So the thing about building a transcription app is that every part of it looks simple until you \
        try to make it work for a two hour meeting recorded on a laptop in a noisy café, and then the \
        captions have to fit on a phone screen held upright, which is where most people will watch them.
        """

    private var metrics: SubtitleBurner.CaptionMetrics {
        SubtitleBurner.CaptionMetrics(style: SubtitleBurner.Style(), renderSize: portrait)
    }

    private var font: CTFont {
        Format.cascadingFont(name: metrics.fontName, size: metrics.fontSize, language: "en")
    }

    private var maxWidth: CGFloat { portrait.width - metrics.horizontalInset * 2 }

    private func transcript(_ segments: [TranscriptSegment], translation: [Int: String]? = nil) -> Transcript {
        Transcript(
            segments: segments,
            language: "en",
            modelName: "test",
            translation: translation.map {
                TranscriptTranslation(targetLanguage: "it", segments: $0, createdAt: Date(), provider: "test")
            }
        )
    }

    private func cues(_ transcript: Transcript, options: ExportOptions = ExportSpec.standard(for: .srt).options) throws -> [BurnCue] {
        try SubtitleBurner.cues(from: transcript, options: options, metrics: metrics, renderSize: portrait)
    }

    private func words(of text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    @Test("a long segment becomes consecutive cues of two lines at most that together say all of it")
    func longSegmentIsSplit() throws {
        let built = try cues(transcript([TranscriptSegment(id: 0, start: 10, end: 22, text: longText)]))

        #expect(built.count > 1)
        for cue in built {
            #expect(cue.text.split(separator: "\n").count <= 2)
            #expect(SubtitleBurner.wrappedLines(cue.text, font: font, maxWidth: maxWidth).count <= 2)
        }
        #expect(built.flatMap { words(of: $0.text) } == words(of: longText))
        #expect(built.first?.start == 10)
        #expect(built.last?.end == 22)
        for (earlier, later) in zip(built, built.dropFirst()) {
            #expect(earlier.end == later.start)
            #expect(earlier.end > earlier.start)
        }
    }

    @Test("no cue is taller than two lines, so nothing is cut off when it's drawn")
    func noCueIsClipped() throws {
        let built = try cues(transcript([TranscriptSegment(id: 0, start: 0, end: 12, text: longText)]))
        let oneLine = SubtitleBurner.measureCaption("Hg", font: font, maxWidth: maxWidth).height
        let twoLines = SubtitleBurner.measureCaption("Hg\nHg", font: font, maxWidth: maxWidth).height
        #expect(twoLines > oneLine * 1.5)
        for cue in built {
            let height = SubtitleBurner.measureCaption(cue.text, font: font, maxWidth: maxWidth).height
            #expect(height <= twoLines, "\(cue.text) measures \(height)")
        }
    }

    @Test("a segment's word timings place the breaks between cues")
    func wordTimingsPlaceTheBreaks() throws {
        let spoken = words(of: longText)
        let timings = spoken.enumerated().map { index, word in
            WordTiming(id: "0-\(index)", word: word, start: Double(index) * 0.5, end: Double(index) * 0.5 + 0.4, probability: 1)
        }
        var segment = TranscriptSegment(id: 0, start: 0, end: Double(spoken.count) * 0.5, text: longText)
        segment.words = timings

        let built = try cues(transcript([segment]))

        #expect(built.count > 1)
        var consumed = 0
        for cue in built.dropLast() {
            consumed += words(of: cue.text).count
            #expect(cue.end == timings[consumed].start)
        }
    }

    @Test("a short segment stays one cue with its own timing")
    func shortSegmentStaysWhole() throws {
        let built = try cues(transcript([TranscriptSegment(id: 0, start: 1, end: 2.5, text: "Hello there.")]))
        #expect(built == [BurnCue(start: 1, end: 2.5, text: "Hello there.")])
    }

    @Test("the caption length setting wraps lines as the SRT export does")
    func captionLengthApplies() throws {
        var options = ExportSpec.standard(for: .srt).options
        options.captionLength = .short
        let built = try cues(transcript([TranscriptSegment(id: 0, start: 0, end: 12, text: longText)]), options: options)
        let lines = built.flatMap { $0.text.split(separator: "\n") }
        #expect(lines.allSatisfy { $0.count <= 32 })
    }

    @Test("a translation export burns the translation")
    func translationIsBurned() throws {
        var options = ExportSpec.standard(for: .srt).options
        options.content = .translation
        let built = try cues(
            transcript([TranscriptSegment(id: 0, start: 0, end: 2, text: "Good morning.")], translation: [0: "Buongiorno."]),
            options: options
        )
        #expect(built.map(\.text) == ["Buongiorno."])
    }

    @Test("a translation burn picks its fallback font from the translation's language")
    func translationUsesItsOwnLanguage() {
        let translated = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 2, text: "Good morning.")],
            language: "en", modelName: "test",
            translation: TranscriptTranslation(targetLanguage: "ja", segments: [0: "おはようございます。"], createdAt: Date(), provider: "test")
        )
        var options = ExportSpec.standard(for: .srt).options
        #expect(SubtitleBurner.captionLanguage(of: translated, options: options) == "en")
        options.content = .both
        #expect(SubtitleBurner.captionLanguage(of: translated, options: options) == "en")
        options.content = .translation
        #expect(SubtitleBurner.captionLanguage(of: translated, options: options) == "ja")
        var untranslated = translated
        untranslated.translation = nil
        #expect(SubtitleBurner.captionLanguage(of: untranslated, options: options) == "en")
    }
}
