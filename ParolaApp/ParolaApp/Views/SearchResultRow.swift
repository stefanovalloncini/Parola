import SwiftUI
import ParolaCore

/// A library row whose detail line is the hit that matched, not the opening of the transcript.
struct SearchResultRow: View {
    /// Where the row's separator starts, so it runs under the text instead of under the badge.
    nonisolated static let separatorInset: CGFloat = DS.Spacing.small + EntryRowMetrics.textInset

    let display: LibraryRowDisplay
    let match: LibrarySearchIndex.Match?
    var isSelected: Bool = false
    /// Set for the whole list, so a row without a time still lines its snippet up with the rows that have one.
    var showsTimestamp: Bool = true

    var body: some View {
        EntryRow(
            display: display,
            detail: .snippet(
                snippetText,
                timecode: Self.timestamp(for: match),
                reservesTimecode: showsTimestamp
            ),
            isSelected: isSelected,
            showsTimeOnly: false
        ) {
            matchCount
        }
    }

    /// nil for an entry matched on its title, summary or speakers, none of which are spoken at a time.
    nonisolated static func timestamp(for match: LibrarySearchIndex.Match?) -> String? {
        match?.firstHit.map { Timecode.format($0.seconds) }
    }

    /// A space, not nothing: an entry matched on its title alone still has to be as tall as its neighbours.
    private var snippetText: AttributedString {
        guard let match, !match.snippet.isEmpty else { return AttributedString(" ") }
        return SearchSnippetText.attributed(match, tinted: !isSelected)
    }

    @ViewBuilder
    private var matchCount: some View {
        if let count = match?.matchCount, count > 0 {
            Text(verbatim: LibraryListContent.matchesLabel(count))
                .font(DS.Font.caption)
                .foregroundStyle(isSelected ? DS.Color.onAccent : DS.Color.accentInk)
                .lineLimit(1)
                .fixedSize()
                .chipChrome(
                    isSelected: isSelected,
                    size: .compact,
                    style: .subtle,
                    selectedFill: DS.Color.onAccentWash,
                    border: isSelected ? DS.Color.onAccent.opacity(0.35) : DS.Color.accent.opacity(0.25)
                )
        }
    }
}
