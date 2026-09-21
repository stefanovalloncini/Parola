import SwiftUI

struct BatchEmptyState: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        EmptyStateView(
            systemImage: "square.stack.3d.up",
            title: "No Batch Jobs Yet",
            message: "Transcribe and export multiple files at once. Add files or drag them onto the app."
        ) {
            Button {
                model.presentBatchOpenPanel()
            } label: {
                Text("Add Files…")
            }
            .buttonStyle(DSPillButtonStyle(kind: .primary))
            .accessibilityIdentifier("batch.addFiles")
        }
    }
}
