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
            Button("Try again") { model.dismissError() }
                .buttonStyle(.bordered)
        }
    }
}
