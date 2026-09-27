import Foundation
import CoreGraphics
import CoreText

/// One caption as the burn draws it: two lines at most.
struct BurnCue: Sendable, Equatable {
    let start: Double
    let end: Double
    let text: String
}

extension SubtitleBurner {
    static let maxLinesPerCue = 2

    /// The cues an SRT export with these options writes, fitted to the frame: wrapped to its width, and a
    /// cue longer than two lines split into consecutive cues, timed by its words when it has them and by
    /// its characters when it doesn't.
    static func cues(
        from transcript: Transcript, options: ExportOptions, metrics: CaptionMetrics, renderSize: CGSize
    ) throws -> [BurnCue] {
        let exporter = SrtExporter(spec: ExportSpec(style: .subtitles, format: .srt, options: options).changing(format: .srt))
        let prepared = exporter.spec.prepared(transcript)
        let font = Format.cascadingFont(name: metrics.fontName, size: metrics.fontSize, language: transcript.language)
        let maxWidth = renderSize.width - metrics.horizontalInset * 2
        var cues: [(order: Int, cue: BurnCue)] = []
        for segment in prepared.segments {
            try Task.checkCancellation()
            guard let text = exporter.cueText(for: segment, in: prepared) else { continue }
            let start = max(segment.start, 0)
            let end = max(segment.end, start + Format.minCaptionSeconds)
            let lines = wrappedLines(text, font: font, maxWidth: maxWidth)
            for cue in split(lines, start: start, end: end, words: segment.words, spokenText: segment.text) {
                cues.append((cues.count, cue))
            }
        }
        return cues.sorted { ($0.cue.start, $0.order) < ($1.cue.start, $1.order) }.map(\.cue)
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

    /// Word timings place the breaks only when the cue says exactly the spoken words; a speaker label,
    /// a translation or a word Core Text broke in two leaves the time shared out by characters.
    static func split(
        _ lines: [String], start: Double, end: Double, words: [WordTiming]?, spokenText: String
    ) -> [BurnCue] {
        guard lines.count > maxLinesPerCue else {
            return [BurnCue(start: start, end: end, text: lines.joined(separator: "\n"))]
        }
        let chunks = stride(from: 0, to: lines.count, by: maxLinesPerCue).map {
            Array(lines[$0..<min($0 + maxLinesPerCue, lines.count)])
        }
        let tokenCounts = chunks.map { $0.joined(separator: " ").split(whereSeparator: \.isWhitespace).count }
        let charCounts = chunks.map { $0.reduce(0) { $0 + $1.count } }
        let spokenTokens = spokenText.split(whereSeparator: \.isWhitespace).count
        let timed = words.flatMap { words in
            words.count == spokenTokens && tokenCounts.reduce(0, +) == spokenTokens ? words : nil
        }
        let totalChars = max(1, charCounts.reduce(0, +))

        var cues: [BurnCue] = []
        var chunkStart = start
        var tokensBefore = 0
        var charsBefore = 0
        for (index, chunk) in chunks.enumerated() {
            var chunkEnd = end
            if index < chunks.count - 1 {
                tokensBefore += tokenCounts[index]
                charsBefore += charCounts[index]
                let boundary = timed.map { $0[tokensBefore].start }
                    ?? start + (end - start) * Double(charsBefore) / Double(totalChars)
                chunkEnd = min(max(boundary, chunkStart + Format.minCaptionSeconds), end)
            }
            cues.append(BurnCue(start: chunkStart, end: chunkEnd, text: chunk.joined(separator: "\n")))
            chunkStart = chunkEnd
        }
        return cues
    }
}
