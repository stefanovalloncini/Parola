import SwiftUI

struct LongPauseDivider: View {
    let seconds: Double

    private var label: String {
        if seconds < 60 { return String(format: "%.0fs silence", seconds) }
        return String(format: "%.1fm silence", seconds / 60)
    }

    var body: some View {
        HStack(spacing: 6) {
            line
            HStack(spacing: 4) {
                Image(systemName: "moon.zzz")
                    .font(DS.Font.caption)
                Text(label)
                    .font(DS.Font.mono)
            }
            .foregroundStyle(DS.Color.secondaryText)
            .padding(.horizontal, DS.Spacing.small)
            .padding(.vertical, DS.Spacing.hair)
            .background(
                Capsule().fill(DS.Color.surfaceElevated)
            )
            line
        }
        .padding(.vertical, DS.Spacing.hair)
    }

    private var line: some View {
        Rectangle()
            .fill(DS.Color.separator.opacity(0.5))
            .frame(height: 1)
    }
}
