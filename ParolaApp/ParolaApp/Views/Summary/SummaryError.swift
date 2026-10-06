import SwiftUI

struct SummaryError: View {
    let message: String
    let offersSettings: Bool
    let onRetry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Couldn't Generate a Summary", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Retry", action: onRetry)
                .buttonStyle(DSPillButtonStyle(kind: .primary))
                .axLeaf("Summary.Button.Retry")
            if offersSettings {
                OpenAISettingsButton(leaf: "Summary.Button.OpenAISettings")
                    .buttonStyle(DSPillButtonStyle(kind: .secondary))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SummaryUnavailable: View {
    let reason: String

    var body: some View {
        ContentUnavailableView {
            Label("Summaries Need Apple Intelligence", systemImage: "sparkles")
        } description: {
            Text(verbatim: reason)
        } actions: {
            OpenAISettingsButton(leaf: "Summary.Button.OpenAISettings")
                .buttonStyle(DSPillButtonStyle(kind: .secondary))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
