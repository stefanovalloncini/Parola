import SwiftUI

/// Ax ids for anything inside `leading`/`trailing` are the caller's own — this view adds no branch of its own.
struct PageHeader<Leading: View, Trailing: View>: View {
    let title: LocalizedStringKey
    let count: String?
    let countHelp: String?
    let leading: Leading
    let trailing: Trailing

    init(
        title: LocalizedStringKey,
        count: String? = nil,
        countHelp: String? = nil,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.count = count
        self.countHelp = countHelp
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: DS.Spacing.regular) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.small) {
                Text(title)
                    .font(DS.Font.title)
                    .foregroundStyle(DS.Color.primaryText)
                if let count {
                    Text(count)
                        .font(DS.Font.caption)
                        .monospacedDigit()
                        .foregroundStyle(DS.Color.secondaryText)
                        .modifier(OptionalHelp(help: countHelp))
                }
            }
            leading
            Spacer()
            trailing
        }
        .padding(.horizontal, DS.Spacing.large)
        .padding(.vertical, DS.Spacing.regular)
    }
}

extension PageHeader where Leading == EmptyView {
    init(
        title: LocalizedStringKey,
        count: String? = nil,
        countHelp: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.init(title: title, count: count, countHelp: countHelp, leading: { EmptyView() }, trailing: trailing)
    }
}
