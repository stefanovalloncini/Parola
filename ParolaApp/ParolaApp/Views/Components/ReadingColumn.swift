import SwiftUI

extension EntryRowMetrics {
    /// The side margin that centres a column of `columnWidth` in a pane `paneWidth` wide; none below it.
    static func columnMargin(paneWidth: CGFloat) -> CGFloat {
        max(0, (paneWidth - columnWidth) / 2)
    }
}

extension EntryRowMetrics {
    /// What a list row's content spans: the column, or the pane when it is narrower, less the list's own 24 pt inset each side.
    static func shelfWidth(paneWidth: CGFloat) -> CGFloat {
        min(paneWidth, columnWidth) - 2 * (DS.Spacing.medium + DS.Spacing.small)
    }
}

/// Keeps a list's rows to a centred reading column. The scroll view stays full width, so a pointer in the margins still scrolls.
private struct ReadingColumn: ViewModifier {
    @State private var paneWidth: CGFloat = 0
    @State private var relayouts = 0

    /// A List that loses its side margins keeps the width it had with them and overflows the pane; a new identity makes it lay out again.
    func body(content: Content) -> some View {
        content
            .safeAreaPadding(.horizontal, EntryRowMetrics.columnMargin(paneWidth: paneWidth))
            .transaction(value: paneWidth) { $0.animation = nil }
            .id(relayouts)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                if EntryRowMetrics.columnMargin(paneWidth: paneWidth) > 0, EntryRowMetrics.columnMargin(paneWidth: width) == 0 {
                    relayouts += 1
                }
                paneWidth = width
            }
    }
}

/// The same margins for what sits above a list, so a page title lines up with its rows.
private struct ReadingColumnMargins: ViewModifier {
    @State private var paneWidth: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, EntryRowMetrics.columnMargin(paneWidth: paneWidth))
            .transaction(value: paneWidth) { $0.animation = nil }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { paneWidth = $0 }
    }
}

extension View {
    func readingColumn() -> some View {
        modifier(ReadingColumn())
    }

    func readingColumnMargins() -> some View {
        modifier(ReadingColumnMargins())
    }
}
