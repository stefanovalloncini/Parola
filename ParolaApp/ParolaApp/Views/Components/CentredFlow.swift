import SwiftUI

/// Lays its subviews out on one centred row, wrapping to the next when the proposed width runs out.
struct CentredFlow: Layout {
    var spacing: CGFloat = DS.Spacing.small

    /// Which subviews share each row. Pure, so the wrapping rule can be checked without a host.
    static func rowIndices(widths: [CGFloat], limit: CGFloat, spacing: CGFloat) -> [[Int]] {
        var rows: [[Int]] = []
        var current: [Int] = []
        var used: CGFloat = 0
        for (index, width) in widths.enumerated() {
            if !current.isEmpty, used + spacing + width > limit {
                rows.append(current)
                current = []
                used = 0
            }
            used = current.isEmpty ? width : used + spacing + width
            current.append(index)
        }
        if !current.isEmpty { rows.append(current) }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(within: proposal.width ?? .infinity, of: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(within: bounds.width, of: subviews) {
            var x = bounds.minX + (bounds.width - row.width) / 2
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        let indices: [Int]
        let width: CGFloat
        let height: CGFloat
    }

    private func rows(within limit: CGFloat, of subviews: Subviews) -> [Row] {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        return Self.rowIndices(widths: sizes.map(\.width), limit: limit, spacing: spacing).map { indices in
            Row(
                indices: indices,
                width: indices.reduce(0) { $0 + sizes[$1].width } + spacing * CGFloat(indices.count - 1),
                height: indices.map { sizes[$0].height }.max() ?? 0
            )
        }
    }
}
