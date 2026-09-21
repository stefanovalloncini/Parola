import SwiftUI

/// What a `PageHeader` measured for itself, so its trailing controls can give width back when the page is narrow.
extension EnvironmentValues {
    @Entry var pageHeaderWidth: CGFloat = 0
}

enum PageHeaderMetrics {
    /// Below this the header's title starts wrapping once a page puts more than a sort control beside it.
    /// The content pane is ~679 pt at the 920 pt window minimum and ~939 pt at 1180 pt.
    static let searchCollapseWidth: CGFloat = 760

    /// An unmeasured header proposes nothing, so it keeps the full field rather than flashing the glyph.
    static func collapsesSearch(width: CGFloat) -> Bool {
        width > 0 && width < searchCollapseWidth
    }
}

/// A `SearchPill` that folds into its glyph on a narrow page and reopens in a popover.
struct CollapsingSearchPill: View {
    @Binding var text: String
    var placeholder: LocalizedStringKey = "Search"
    var identifier: String = "search.field"
    var clearButtonIdentifier: String = "search.field.clear"
    var expandIdentifier: String = "search.field.expand"
    var width: CGFloat = 220

    @Environment(\.pageHeaderWidth) private var pageWidth
    @State private var expanded = false

    var body: some View {
        if PageHeaderMetrics.collapsesSearch(width: pageWidth) {
            expandButton
        } else {
            field.frame(maxWidth: width)
        }
    }

    private var field: some View {
        SearchPill(
            text: $text,
            placeholder: placeholder,
            identifier: identifier,
            clearButtonIdentifier: clearButtonIdentifier
        )
    }

    private var expandButton: some View {
        Button {
            expanded.toggle()
        } label: {
            Image(systemName: text.isEmpty ? "magnifyingglass" : "line.3.horizontal.decrease.circle.fill")
        }
        .buttonStyle(DSIconChipButtonStyle(side: 26))
        .help("Search")
        .accessibilityLabel("Search")
        .accessibilityIdentifier(expandIdentifier)
        .popover(isPresented: $expanded, arrowEdge: .bottom) {
            field
                .frame(width: width)
                .padding(DS.Spacing.small)
        }
    }
}
