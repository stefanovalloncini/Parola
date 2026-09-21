import SwiftUI
import ParolaCore

struct KindShare: Equatable {
    let category: EntryCategory
    let share: Double

    /// One segment per kind with entries, sized by its share of the total; nothing when there is no total.
    static func shares(counts: [(EntryCategory, Int)]) -> [KindShare] {
        let total = counts.reduce(0) { $0 + max(0, $1.1) }
        guard total > 0 else { return [] }
        return counts.compactMap { category, count in
            count > 0 ? KindShare(category: category, share: Double(count) / Double(total)) : nil
        }
    }
}

struct KindShareBar: View {
    let shares: [KindShare]

    static let height: CGFloat = 8
    static let gap: CGFloat = 2

    var body: some View {
        GeometryReader { proxy in
            let usable = max(0, proxy.size.width - Self.gap * CGFloat(max(0, shares.count - 1)))
            HStack(spacing: Self.gap) {
                ForEach(shares, id: \.category) { share in
                    Rectangle()
                        .fill(DS.categoryTint(for: share.category))
                        .frame(width: usable * share.share)
                }
            }
        }
        .frame(height: Self.height)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous))
        .accessibilityHidden(true)
        .axLeaf("Bar.Kinds")
    }
}
