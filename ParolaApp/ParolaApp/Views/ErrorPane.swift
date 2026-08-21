import SwiftUI

struct ErrorPane: View {
    let message: String
    @Environment(AppModel.self) private var model
    var body: some View {
        ContentUnavailableView {
            Label("Something went wrong", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            if model.failedTakeAudioURL != nil {
                Button("Retry Transcription") { model.retryFailedTake() }
                    .buttonStyle(.borderedProminent)
                    .axLeaf("Error.Button.RetryTake")
            }
            Button("Dismiss") { model.dismissError() }
                .buttonStyle(.bordered)
                .axLeaf("Error.Button.Dismiss")
        }
    }
}
