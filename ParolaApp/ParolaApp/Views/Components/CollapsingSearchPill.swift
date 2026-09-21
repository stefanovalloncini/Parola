import SwiftUI

/// What a `PageHeader` measured for itself, so its trailing controls can give width back when the page is narrow.
extension EnvironmentValues {
    @Entry var pageHeaderWidth: CGFloat = 0
}

enum PageHeaderMetrics {
    /// The content pane is ~679 pt at the 920 pt window minimum and ~939 pt at 1180 pt.
    static let searchCollapseWidth: CGFloat = 760

    /// An unmeasured header proposes nothing, so it keeps the full field rather than flashing the glyph.
    static func collapsesSearch(width: CGFloat) -> Bool {
        width > 0 && width < searchCollapseWidth
    }

    /// The popover hangs off the glyph, so a resize that crosses the threshold takes its anchor with it.
    static func popoverSurvives(resizeFrom old: CGFloat, to new: CGFloat) -> Bool {
        collapsesSearch(width: old) == collapsesSearch(width: new)
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
        Group {
            if PageHeaderMetrics.collapsesSearch(width: pageWidth) {
                expandButton
            } else {
                field().frame(maxWidth: width)
            }
        }
        .onChange(of: pageWidth) { old, new in
            if !PageHeaderMetrics.popoverSurvives(resizeFrom: old, to: new) { expanded = false }
        }
    }

    private func field(focusesOnAppear: Bool = false) -> some View {
        SearchPill(
            text: $text,
            placeholder: placeholder,
            identifier: identifier,
            clearButtonIdentifier: clearButtonIdentifier,
            focusesOnAppear: focusesOnAppear
        )
    }

    private var expandButton: some View {
        Button {
            expanded.toggle()
        } label: {
            Image(systemName: text.isEmpty ? "magnifyingglass" : "line.3.horizontal.decrease.circle.fill")
        }
        .buttonStyle(DSIconChipButtonStyle(side: 26))
        .help(placeholder)
        .accessibilityLabel(placeholder)
        .accessibilityIdentifier(expandIdentifier)
        .popover(isPresented: $expanded, arrowEdge: .bottom) {
            field(focusesOnAppear: true)
                .frame(width: width)
                .padding(DS.Spacing.small)
        }
    }
}
