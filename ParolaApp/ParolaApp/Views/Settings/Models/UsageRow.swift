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
                .font(DS.Font.bodyStrong)
                .foregroundStyle(DS.Color.secondaryText)
            Text(value)
                .font(DS.Font.body.monospacedDigit())
                .foregroundStyle(.primary)
            Spacer()
        }
    }
}
