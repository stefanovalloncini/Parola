import Foundation
import CoreGraphics
import CoreText

/// One caption as the burn draws it: two lines at most, unless its segment is too short to split.
struct BurnCue: Sendable, Equatable {
    let start: Double
    let end: Double
    let text: String
}

extension SubtitleBurner {
    /// The cues an SRT export would write, packed by columns; Core Text checks each final line and a segment with one that is too wide is packed again by measured width.
    static func cues(
        from transcript: Transcript, options: ExportOptions, metrics: CaptionMetrics, renderSize: CGSize
    ) throws -> [BurnCue] {
        let spec = ExportSpec(style: .subtitles, format: .srt, options: options).changing(format: .srt)
        let font = Format.cascadingFont(
            name: metrics.fontName, size: metrics.fontSize, language: captionLanguage(of: transcript, options: options)
        )
        let maxWidth = renderSize.width - metrics.horizontalInset * 2
        let safeWidth = Double(maxWidth) * 0.97
        let spaceAdvance = lineWidth("a a", font: font) - lineWidth("aa", font: font)
        let columnWidth = lineWidth("abcdefghijklmnopqrstuvwxyz", font: font) / 26
        let characterLimit = options.captionLength.maxCharsPerLine
        let columns = characterLimit ?? max(8, Int(safeWidth / max(columnWidth, 1)))
        let verification = CaptionCues.Verification(
            fits: { line in
                lineWidth(line, font: font) <= safeWidth || wrappedLines(line, font: font, maxWidth: maxWidth).count <= 1
            },
            fallback: .advances(
                limit: safeWidth, characterLimit: characterLimit ?? .max, spaceAdvance: spaceAdvance,
                advance: { lineWidth($0, font: font) }
            )
        )
        let label: (String) -> String = { "\($0): " }
        let cues = try CaptionCues.cues(
            for: CaptionCues.sources(from: transcript, spec: spec), breaker: .characters(columns), speakerPrefix: label,
            verifying: verification
        )
        return cues.map { BurnCue(start: $0.start, end: $0.end, text: $0.shownLines(speakerPrefix: label).joined(separator: "\n")) }
    }

    private static func lineWidth(_ text: String, font: CTFont) -> Double {
        let attributed = captionText(text, font: font, color: CGColor(gray: 1, alpha: 1))
        return CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributed), nil, nil, nil)
    }

    /// The language the cues are written in, which picks the fallback font for their script.
    static func captionLanguage(of transcript: Transcript, options: ExportOptions) -> String {
        guard options.content == .translation, let target = transcript.translation?.targetLanguage else {
            return transcript.language
        }
        return target
    }

    /// The lines Core Text breaks the text into at this width, which are the lines the burn draws.
    static func wrappedLines(_ text: String, font: CTFont, maxWidth: CGFloat) -> [String] {
        guard maxWidth > 0 else { return [text] }
        let attributed = captionText(text, font: font, color: CGColor(gray: 1, alpha: 1))
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: maxWidth, height: 1_000_000), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        let source = attributed.string as NSString
        return (CTFrameGetLines(frame) as? [CTLine] ?? []).compactMap { line in
            let range = CTLineGetStringRange(line)
            let piece = source.substring(with: NSRange(location: range.location, length: range.length))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return piece.isEmpty ? nil : piece
        }
    }
}
