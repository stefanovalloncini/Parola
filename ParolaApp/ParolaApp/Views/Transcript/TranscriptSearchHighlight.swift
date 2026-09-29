import SwiftUI
import ParolaCore

/// How a search match is painted wherever a transcript shows: every match marked, the current one in accent.
@MainActor
enum TranscriptSearchHighlight {
    static func background(isCurrent: Bool) -> Color {
        isCurrent ? DS.Color.accentFill : Color.yellow
    }

    static func foreground(isCurrent: Bool) -> Color {
        isCurrent ? DS.Color.onAccent : .black
    }

    /// A segment's text with its matches painted, trimmed as an unmatched segment renders it so nothing shifts while typing.
    static func attributed(
        _ rawText: String,
        matches: [TranscriptMatch],
        currentMatchID: TranscriptMatch.ID?
    ) -> AttributedString {
        let body = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        var attributed = AttributedString(body)
        paint(
            in: &attributed,
            runOffsets: 0..<body.count,
            rawText: rawText,
            matches: matches,
            currentMatchID: currentMatchID
        )
        return attributed
    }

    /// Paints a segment's matches inside a flowing-text chunk, where the segment sits at `runOffsets`.
    static func paint(
        in text: inout AttributedString,
        runOffsets: Range<Int>,
        rawText: String,
        matches: [TranscriptMatch],
        currentMatchID: TranscriptMatch.ID?
    ) {
        let body = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        // The chunk builder can prefix the run with the space that separates it from the segment before.
        let prefix = runOffsets.count - body.count
        guard prefix >= 0 else { return }
        let leading = rawText.prefix(while: { $0.isWhitespace || $0.isNewline }).count
        for match in matches {
            guard let range = bodyRange(of: match, in: rawText, leading: leading, bodyCount: body.count) else {
                continue
            }
            let lower = runOffsets.lowerBound + prefix + range.lowerBound
            let upper = runOffsets.lowerBound + prefix + range.upperBound
            guard upper <= runOffsets.upperBound else { continue }
            recolor(&text, lower..<upper, isCurrent: match.id == currentMatchID)
        }
    }

    /// A match's UTF-16 range in the stored text, as character offsets into the trimmed body.
    private static func bodyRange(
        of match: TranscriptMatch,
        in rawText: String,
        leading: Int,
        bodyCount: Int
    ) -> Range<Int>? {
        guard
            let low16 = rawText.utf16.index(
                rawText.utf16.startIndex, offsetBy: match.range.lowerBound, limitedBy: rawText.utf16.endIndex
            ),
            let high16 = rawText.utf16.index(
                rawText.utf16.startIndex, offsetBy: match.range.upperBound, limitedBy: rawText.utf16.endIndex
            ),
            let low = String.Index(low16, within: rawText),
            let high = String.Index(high16, within: rawText)
        else { return nil }
        let start = rawText.distance(from: rawText.startIndex, to: low) - leading
        let end = rawText.distance(from: rawText.startIndex, to: high) - leading
        guard start >= 0, end <= bodyCount, start < end else { return nil }
        return start..<end
    }

    private static func recolor(_ text: inout AttributedString, _ offsets: Range<Int>, isCurrent: Bool) {
        let characters = text.characters
        guard
            let low = characters.index(characters.startIndex, offsetBy: offsets.lowerBound, limitedBy: characters.endIndex),
            let high = characters.index(characters.startIndex, offsetBy: offsets.upperBound, limitedBy: characters.endIndex),
            low < high
        else { return }
        text[low..<high].backgroundColor = background(isCurrent: isCurrent)
        text[low..<high].foregroundColor = foreground(isCurrent: isCurrent)
    }
}
