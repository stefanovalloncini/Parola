import SwiftUI

/// The one empty-state layout every route uses: symbol, title, optional message, pill actions.
struct EmptyStateView<Actions: View>: View {
    let systemImage: String
    let title: LocalizedStringKey
    var message: LocalizedStringKey?
    @ViewBuilder let actions: Actions
    private let hasActions: Bool

    @ScaledMetric(relativeTo: .largeTitle) private var iconSize: CGFloat = 40

    init(
        systemImage: String,
        title: LocalizedStringKey,
        message: LocalizedStringKey? = nil,
        @ViewBuilder actions: () -> Actions
    ) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.actions = actions()
        self.hasActions = Actions.self != EmptyView.self
    }

    var body: some View {
        VStack(spacing: DS.Spacing.small) {
            Image(systemName: systemImage)
                .font(.system(size: iconSize, weight: .light))
                .foregroundStyle(DS.Color.secondaryText.opacity(0.55))
                .padding(.bottom, DS.Spacing.tight)
            Text(title)
                .font(DS.Font.display)
                .foregroundStyle(DS.Color.primaryText)
            if let message {
                Text(message)
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Color.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if hasActions {
                HStack(spacing: DS.Spacing.small) {
                    actions
                }
                .padding(.top, DS.Spacing.small)
            }
        }
        // A floor too: proposed no width the message wraps per character, and the route's minimum height explodes.
        .frame(minWidth: MainWindowLayout.narrowestPaneWidth - 2 * DS.Spacing.large, maxWidth: 420)
        .padding(DS.Spacing.large)
    }
}

extension EmptyStateView where Actions == EmptyView {
    init(systemImage: String, title: LocalizedStringKey, message: LocalizedStringKey? = nil) {
        self.init(systemImage: systemImage, title: title, message: message) { EmptyView() }
    }
}
