import SwiftUI

struct SummaryError: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            Label("Couldn't Generate a Summary", systemImage: "exclamationmark.triangle")
                .font(DS.Font.heading)
                .foregroundStyle(DS.Color.dangerText)
            Text(message)
                .font(DS.Font.secondary)
                .foregroundStyle(DS.Color.secondaryText)
        }
        .padding(DS.Spacing.large)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
