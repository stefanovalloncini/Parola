import SwiftUI

struct UsageRow: View {
    let icon: String
    let label: LocalizedStringKey
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(DS.Color.secondaryText)
            Text(label)
                .font(DS.Font.calloutMedium)
                .foregroundStyle(DS.Color.secondaryText)
            Text(value)
                .font(DS.Font.callout)
                .monospacedDigit()
                .foregroundStyle(.primary)
            Spacer()
        }
        .padding(.horizontal, DS.Spacing.medium)
        .padding(.vertical, DS.Spacing.small)
    }
}
