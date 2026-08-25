import SwiftUI

struct BatchEmptyState: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        EmptyStateView(
            systemImage: "square.stack.3d.up",
            title: "Batch Mode",
            message: "Transcribe and export multiple files at once. Select files or drag them onto the app."
        ) {
            Button {
                model.presentBatchOpenPanel()
            } label: {
                Text("Open Files")
            }
            .buttonStyle(DSPillButtonStyle(kind: .primary))
            .accessibilityIdentifier("batch.openFiles")
        }
    }
}
