import SwiftUI
import ParolaCore

struct SearchResultRow: View {
    nonisolated private static let glyphWidth: CGFloat = 22

    /// Where the row's separator starts, so it runs under the text instead of under the glyph column.
    nonisolated static let separatorInset: CGFloat = DS.Spacing.small + glyphWidth + DS.Spacing.regular

    /// Wide enough for h:mm:ss under ten hours, so the snippets of a mixed list start on the same column.
    nonisolated static let timestampWidth: CGFloat = 52

    let display: LibraryRowDisplay
    let match: LibrarySearchIndex.Match?
    var isSelected: Bool = false
    /// Set for the whole list, so a row without a time still lines its snippet up with the rows that have one.
    var showsTimestamp: Bool = true

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: DS.Spacing.regular) {
            Image(systemName: DS.categorySymbol(for: display.entry.category))
                .font(DS.Font.bodyMedium)
                .foregroundStyle(secondaryStyle)
                .frame(width: Self.glyphWidth, alignment: .center)
            VStack(alignment: .leading, spacing: DS.Spacing.tight) {
                titleLine
                snippet
            }
        }
        .padding(.vertical, DS.Spacing.regular)
        .padding(.horizontal, DS.Spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .help(display.tooltip)
        .animation(reduceMotion ? nil : DS.Motion.rowState, value: isHovering)
        .onHover { isHovering = $0 }
    }

    private var titleLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.small) {
            Text(display.title)
                .font(DS.Font.bodyStrong)
                .foregroundStyle(DS.Color.primaryText)
                .lineLimit(1)
            Spacer(minLength: DS.Spacing.small)
            MetaLine([meta], tint: secondaryStyle)
                .layoutPriority(1)
        }
    }

    /// nil for an entry matched on its title, summary or speakers, none of which are spoken at a time.
    nonisolated static func timestamp(for match: LibrarySearchIndex.Match?) -> String? {
        match?.firstHit.map { Timecode.format($0.seconds) }
    }

    private var snippet: some View {
        let timestamp = Self.timestamp(for: match)
        return HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.small) {
            if showsTimestamp {
                // Hidden rather than empty: an empty Text sits on a different baseline and shifts the row.
                Text(timestamp ?? "00:00")
                    .font(model.monospacedTimestamps ? DS.Font.mono : DS.Font.secondary)
                    .foregroundStyle(secondaryStyle)
                    .lineLimit(1)
                    .opacity(timestamp == nil ? 0 : 1)
                    .accessibilityLabel(Text("First match at \(timestamp ?? "")"))
                    .accessibilityHidden(timestamp == nil)
                    .frame(width: Self.timestampWidth, alignment: .leading)
            }
            Text(snippetText)
                .font(DS.Font.body)
                .foregroundStyle(secondaryStyle)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A space, not nothing: an entry matched on its title alone still has to be as tall as its neighbours.
    private var snippetText: AttributedString {
        guard let match, !match.snippet.isEmpty else { return AttributedString(" ") }
        return SearchSnippetText.attributed(match, tinted: !isSelected)
    }

    /// The palette's secondary is a fixed grey; on the accent fill of a selected row only the system's flips with it.
    private var secondaryStyle: Color {
        isSelected ? .secondary : DS.Color.secondaryText
    }

    private var meta: String {
        LibraryListContent.resultMeta(
            category: display.entry.category,
            date: display.shortDate,
            matches: match?.matchCount ?? 0
        )
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isHovering, !isSelected {
            RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                .fill(DS.Palette.surfaceHover)
        }
    }
}
