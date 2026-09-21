import SwiftUI
import ParolaCore

/// Search painting for the viewer: the same two tints the main transcript uses, applied to a plain
/// string so the window can render a segment without the editing machinery behind it.
@MainActor
enum EntryViewerText {
    static func highlighted(
        _ text: String,
        matches: [TranscriptMatch],
        currentMatchID: TranscriptMatch.ID?
    ) -> AttributedString {
        var attributed = AttributedString(text)
        for match in matches {
            guard
                let stringLow = text.utf16.index(
                    text.utf16.startIndex, offsetBy: match.range.lowerBound, limitedBy: text.utf16.endIndex
                ),
                let stringHigh = text.utf16.index(
                    text.utf16.startIndex, offsetBy: match.range.upperBound, limitedBy: text.utf16.endIndex
                ),
                let low = AttributedString.Index(stringLow, within: attributed),
                let high = AttributedString.Index(stringHigh, within: attributed)
            else { continue }
            let isCurrent = match.id == currentMatchID
            attributed[low..<high].backgroundColor = isCurrent ? DS.Color.accent : Color.yellow
            attributed[low..<high].foregroundColor = Color.black
        }
        return attributed
    }
}
