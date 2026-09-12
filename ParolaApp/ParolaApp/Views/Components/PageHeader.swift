import SwiftUI

/// Ax ids for anything inside `leading`/`trailing` are the caller's own — this view adds no branch of its own.
struct PageHeader<Leading: View, Trailing: View>: View {
    let title: Text
    let count: String?
    let countHelp: String?
    let countAxID: String?
    let leading: Leading
    let trailing: Trailing

    init(
        title: LocalizedStringKey,
        count: String? = nil,
        countHelp: String? = nil,
        countAxID: String? = nil,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = Text(title)
        self.count = count
        self.countHelp = countHelp
        self.countAxID = countAxID
        self.leading = leading()
        self.trailing = trailing()
    }

    /// For a runtime title (a document name, say) that must render verbatim, not be looked up as a catalog key.
    @_disfavoredOverload
    init(
        title: String,
        count: String? = nil,
        countHelp: String? = nil,
        countAxID: String? = nil,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = Text(verbatim: title)
        self.count = count
        self.countHelp = countHelp
        self.countAxID = countAxID
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: DS.Spacing.regular) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.small) {
                title
                    .font(DS.Font.title)
                    .foregroundStyle(DS.Color.primaryText)
                if let count {
                    countText(count)
                }
            }
            leading
            Spacer()
            trailing
        }
        .padding(.horizontal, DS.Spacing.large)
        .padding(.vertical, DS.Spacing.regular)
    }

    @ViewBuilder
    private func countText(_ count: String) -> some View {
        let text = Text(count)
            .font(DS.Font.secondary)
            .monospacedDigit()
            .foregroundStyle(DS.Color.secondaryText)
            .modifier(OptionalHelp(help: countHelp))
        if let countAxID {
            text.axLeaf(countAxID)
        } else {
            text
        }
    }
}

extension PageHeader where Leading == EmptyView {
    init(
        title: LocalizedStringKey,
        count: String? = nil,
        countHelp: String? = nil,
        countAxID: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.init(title: title, count: count, countHelp: countHelp, countAxID: countAxID, leading: { EmptyView() }, trailing: trailing)
    }

    @_disfavoredOverload
    init(
        title: String,
        count: String? = nil,
        countHelp: String? = nil,
        countAxID: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.init(title: title, count: count, countHelp: countHelp, countAxID: countAxID, leading: { EmptyView() }, trailing: trailing)
    }
}
