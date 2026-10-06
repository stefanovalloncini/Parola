import SwiftUI

struct SummaryError: View {
    let message: String
    let onTryAgain: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Couldn't Generate a Summary", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again", action: onTryAgain)
                .buttonStyle(DSPillButtonStyle(kind: .primary))
                .axLeaf("Summary.Button.TryAgain")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
