import SwiftUI

struct ErrorPane: View {
    let message: String

    var body: some View {
        ErrorBanner(message: message)
            .padding(DS.Spacing.large)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// A card the route keeps behind: a failed run shouldn't cost the user the drop zone.
struct ErrorBanner: View {
    let message: String
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .top, spacing: DS.Spacing.regular) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(DS.Font.title3)
                .foregroundStyle(DS.Color.danger)
            VStack(alignment: .leading, spacing: DS.Spacing.tight) {
                Text(title)
                    .font(DS.Font.heading)
                    .foregroundStyle(DS.Color.primaryText)
                Text(AppModel.errorDetail(from: message))
                    .font(DS.Font.callout)
                    .foregroundStyle(DS.Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: DS.Spacing.small) {
                    if model.canRetryFailedTranscription {
                        Button("Retry") { model.retryFailedTranscription() }
                            .buttonStyle(DSPillButtonStyle(kind: .primary, size: .compact))
                            .axLeaf("Error.Button.RetryTake")
                    }
                    if model.failedFileURL != nil {
                        Button("Reveal in Finder") { model.revealFailedFile() }
                            .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
                            .axLeaf("Error.Button.RevealInFinder")
                    }
                    Button("Dismiss") { model.dismissError() }
                        .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
                        .axLeaf("Error.Button.Dismiss")
                }
                .padding(.top, DS.Spacing.small)
            }
            Spacer(minLength: 0)
        }
        .padding(DS.Spacing.regular)
        // A width floor: proposed no width the message wraps per character and the route's height explodes.
        .frame(minWidth: MainWindowLayout.narrowestPaneWidth, maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous)
                .fill(DS.Color.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous)
                .strokeBorder(DS.Color.danger.opacity(0.4), lineWidth: 1)
        )
    }

    private var title: LocalizedStringKey {
        guard let name = model.failedSourceName, !name.isEmpty else { return "Something went wrong" }
        return "Couldn't transcribe \(name)"
    }
}
