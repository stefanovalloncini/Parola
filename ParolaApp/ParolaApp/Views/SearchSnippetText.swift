import SwiftUI
import ParolaCore

/// The matching line under a search result, with the terms the index found picked out.
enum SearchSnippetText {
    static func attributed(_ match: LibrarySearchIndex.Match) -> AttributedString {
        let characters = Array(match.snippet)
        var text = AttributedString()
        var cursor = 0
        for range in markedRanges(match) where range.lowerBound >= cursor {
            if range.lowerBound > cursor {
                text.append(AttributedString(String(characters[cursor..<range.lowerBound])))
            }
            var hit = AttributedString(String(characters[range]))
            hit.foregroundColor = DS.Color.highlight
            hit.font = DS.Font.captionEmphasized
            text.append(hit)
            cursor = range.upperBound
        }
        if cursor < characters.count {
            text.append(AttributedString(String(characters[cursor...])))
        }
        return text
    }

    /// The index counts in characters, so the ranges do too — clamped to what the snippet holds.
    static func markedRanges(_ match: LibrarySearchIndex.Match) -> [Range<Int>] {
        let count = match.snippet.count
        return match.highlights.compactMap { highlight in
            guard highlight.length > 0, highlight.start >= 0, highlight.start < count else { return nil }
            return highlight.start..<min(highlight.start + highlight.length, count)
        }
    }
}
