import SwiftUI

struct BarPill<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 8) { content }
            .padding(.horizontal, DS.Spacing.small)
            .frame(height: 28)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous)
                    .fill(DS.Color.surfaceElevated.opacity(0.85))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous)
                    .stroke(DS.Color.separator.opacity(0.4), lineWidth: 0.5)
            )
    }
}
