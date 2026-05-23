import SwiftUI

struct SummaryError: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            Label("Couldn't generate a summary", systemImage: "exclamationmark.triangle")
                .font(DS.Font.heading)
                .foregroundStyle(DS.Color.danger)
            Text(message)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.secondaryText)
        }
        .padding(DS.Spacing.large)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
