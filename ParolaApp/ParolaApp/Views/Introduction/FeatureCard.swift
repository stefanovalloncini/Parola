import SwiftUI

/// One feature in the grid: what it is on the left, a looping sketch of it on the right.
struct FeatureCard: View {
    let item: FeatureRow.Item
    let hotkeyName: String

    var body: some View {
        HStack(alignment: .center, spacing: DS.Spacing.regular) {
            FeatureRow(item: item)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let kind = FeatureVignetteKind(symbol: item.symbol) {
                FeatureVignette(kind: kind, hotkeyName: hotkeyName)
            }
        }
        .padding(DS.Spacing.medium)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous)
                .fill(DS.Color.surfaceElevated)
        )
    }
}
