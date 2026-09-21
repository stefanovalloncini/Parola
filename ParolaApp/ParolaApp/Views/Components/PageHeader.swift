import SwiftUI

/// Ax ids for anything inside `leading`/`trailing` are the caller's own — this view adds no branch of its own.
struct PageHeader<Leading: View, Trailing: View>: View {
    let title: Text
    let subtitle: String?
    let subtitleHelp: String?
    let subtitleAxID: String?
    let leading: Leading
    let trailing: Trailing

    init(
        title: LocalizedStringKey,
        subtitle: String? = nil,
        subtitleHelp: String? = nil,
        subtitleAxID: String? = nil,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = Text(title)
        self.subtitle = subtitle
        self.subtitleHelp = subtitleHelp
        self.subtitleAxID = subtitleAxID
        self.leading = leading()
        self.trailing = trailing()
    }

    /// For a runtime title (a document name, say) that must render verbatim, not be looked up as a catalog key.
    @_disfavoredOverload
    init(
        title: String,
        subtitle: String? = nil,
        subtitleHelp: String? = nil,
        subtitleAxID: String? = nil,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = Text(verbatim: title)
        self.subtitle = subtitle
        self.subtitleHelp = subtitleHelp
        self.subtitleAxID = subtitleAxID
        self.leading = leading()
        self.trailing = trailing()
    }

    @State private var measuredWidth: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.hair) {
            HStack(spacing: DS.Spacing.regular) {
                title
                    .font(DS.Font.title)
                    .foregroundStyle(DS.Color.primaryText)
                leading
                Spacer()
                trailing
            }
            if let subtitle {
                subtitleText(subtitle)
            }
        }
        .padding(.horizontal, DS.Spacing.large)
        .padding(.vertical, DS.Spacing.regular)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measuredWidth = $0 }
        .environment(\.pageHeaderWidth, measuredWidth)
    }

    @ViewBuilder
    private func subtitleText(_ subtitle: String) -> some View {
        let text = Text(subtitle)
            .font(DS.Font.secondary)
            .monospacedDigit()
            .foregroundStyle(DS.Color.secondaryText)
            .modifier(OptionalHelp(help: subtitleHelp))
        if let subtitleAxID {
            text.axLeaf(subtitleAxID)
        } else {
            text
        }
    }
}

extension PageHeader where Leading == EmptyView {
    init(
        title: LocalizedStringKey,
        subtitle: String? = nil,
        subtitleHelp: String? = nil,
        subtitleAxID: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.init(
            title: title,
            subtitle: subtitle,
            subtitleHelp: subtitleHelp,
            subtitleAxID: subtitleAxID,
            leading: { EmptyView() },
            trailing: trailing
        )
    }

    @_disfavoredOverload
    init(
        title: String,
        subtitle: String? = nil,
        subtitleHelp: String? = nil,
        subtitleAxID: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.init(
            title: title,
            subtitle: subtitle,
            subtitleHelp: subtitleHelp,
            subtitleAxID: subtitleAxID,
            leading: { EmptyView() },
            trailing: trailing
        )
    }
}
