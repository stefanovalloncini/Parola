import SwiftUI

/// The one empty-state layout every route uses: the system's, with pill actions.
struct EmptyStateView<Actions: View>: View {
    let systemImage: String
    let title: LocalizedStringKey
    var message: LocalizedStringKey?
    @ViewBuilder let actions: Actions
    private let hasActions: Bool

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
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            if let message {
                Text(message)
            }
        } actions: {
            if hasActions {
                // Wrapping rather than squeezing: two pills can overrun a narrow pane in Italian.
                CentredFlow(spacing: DS.Spacing.small) {
                    actions
                }
            }
        }
    }
}

extension EmptyStateView where Actions == EmptyView {
    init(systemImage: String, title: LocalizedStringKey, message: LocalizedStringKey? = nil) {
        self.init(systemImage: systemImage, title: title, message: message) { EmptyView() }
    }
}

/// What a list says when its search or its filters leave nothing: one title, and a quiet way back when filters did it.
struct NoResultsView: View {
    /// The source key, so the casing rule can be asserted over it.
    static let title = "No Results"

    var systemImage = "magnifyingglass"
    var message: LocalizedStringKey?
    var clearFilters: (() -> Void)?

    var body: some View {
        EmptyStateView(systemImage: systemImage, title: LocalizedStringKey(Self.title), message: message) {
            if let clearFilters {
                Button("Clear Filters", action: clearFilters)
                    .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
                    .axLeaf("Button.ClearFilters")
            }
        }
    }
}
