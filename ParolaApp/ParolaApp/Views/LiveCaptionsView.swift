import SwiftUI
import ParolaCore

struct LiveCaptionsView: View {
    @ObservedObject var controller: LiveCaptionsController

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            if let error = controller.state.error {
                Text(error)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.danger)
            } else if controller.state.displayedText.isEmpty {
                Text("Listening…")
                    .font(DS.Font.body)
                    .foregroundStyle(.secondary)
            } else {
                Text(controller.state.displayedText)
                    .font(DS.Font.body)
                    .foregroundStyle(.primary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DS.Spacing.regular)
        .frame(minWidth: 480, maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.7))
        .foregroundStyle(.white)
    }
}
