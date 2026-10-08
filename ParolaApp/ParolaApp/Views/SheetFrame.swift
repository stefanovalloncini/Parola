import SwiftUI

/// A sheet as macOS 26 draws one: a bold title and its line, the content, a hairline over the buttons, no fill.
struct SheetFrame<Content: View, Footer: View>: View {
    private let titleText: Text
    let onClose: () -> Void
    let content: Content
    let footer: Footer
    private var width: CGFloat = 480
    private var minHeight: CGFloat = 220
    private var maxHeight: CGFloat = 640
    private var description: Text?
    private var descriptionLeaf = "Sheet.Text.Description"
    private var footerCancels = false

    static var margin: CGFloat { 20 }

    func sheetSize(width: CGFloat, minHeight: CGFloat = 220, maxHeight: CGFloat = 640) -> SheetFrame {
        var copy = self
        copy.width = width
        copy.minHeight = minHeight
        copy.maxHeight = maxHeight
        return copy
    }

    /// The footer carries its own Cancel or Close for ⎋; without one, the frame closes the sheet on ⎋.
    func footerHasCancel(_ hasCancel: Bool = true) -> SheetFrame {
        var copy = self
        copy.footerCancels = hasCancel
        return copy
    }

    func sheetDescription(_ text: Text, leaf: String = "Sheet.Text.Description") -> SheetFrame {
        var copy = self
        copy.description = text
        copy.descriptionLeaf = leaf
        return copy
    }

    init(
        title: LocalizedStringKey,
        onClose: @escaping () -> Void,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.titleText = Text(title)
        self.onClose = onClose
        self.content = content()
        self.footer = footer()
    }

    init(
        titleVerbatim: String,
        onClose: @escaping () -> Void,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.titleText = Text(titleVerbatim)
        self.onClose = onClose
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            content
                .padding(.horizontal, Self.margin - DS.Spacing.regular)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            footer
                .padding(.horizontal, Self.margin)
                .padding(.top, DS.Spacing.medium)
                .padding(.bottom, Self.margin)
        }
        .background { if !footerCancels { escapeCloses } }
        .frame(width: width)
        .frame(minHeight: minHeight, maxHeight: maxHeight)
        .tint(DS.Color.accent)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.hair) {
            titleText
                .font(DS.Font.sheetTitle)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
                .axLeaf("Sheet.Text.Title")
            if let description {
                description
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Color.secondaryText)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .axLeaf(descriptionLeaf)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Self.margin)
        .padding(.top, Self.margin)
        .padding(.bottom, DS.Spacing.tight)
    }

    private var escapeCloses: some View {
        Button("Close", action: onClose)
            .keyboardShortcut(.cancelAction)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }
}
